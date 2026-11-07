import Foundation

// Codex local token/cost statistics.
// Scans Codex CLI session logs (~/.codex/sessions + archived_sessions) for
// token_count events, attributes them to local days by their own timestamps,
// and prices them with the models.dev catalog (cached 24h, openai subset only),
// the same source CodexBar uses. Dollar figures are list-price estimates.
// Unchanged files are not rescanned: per-file results are cached by mtime+size.
//
// models.dev attribution: the price catalog is fetched at runtime from the
// public models.dev API (https://models.dev/api.json, MIT-licensed open
// source project, anomalyco/models.dev). No models.dev data is bundled in
// this repository; only the openai price subset is cached locally, for 24h.

struct DayStat {
    var tokens: Int = 0
    var cost: Double = 0
    var unpricedTokens: Int = 0
}

final class PricingTable {
    private var table: [String: (input: Double, output: Double, cacheRead: Double)] = [:]
    private(set) var version: Int = 0
    private let cacheURL: URL
    private var loaded = false

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("QuotaMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("models-dev.json")
    }

    func ensureLoaded() {
        if loaded { return }
        loaded = true
        var stale = true
        if let data = try? Data(contentsOf: cacheURL) {
            parse(data)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
               let mtime = attrs[.modificationDate] as? Date,
               let size = attrs[.size] as? NSNumber {
                // Refresh when older than 24h, or when the cache is an old
                // full-catalog file (>2MB) that should be trimmed down.
                stale = Date().timeIntervalSince(mtime) > 24 * 3600 || size.intValue > 2_000_000
            }
        }
        if stale {
            var req = URLRequest(url: URL(string: "https://models.dev/api.json")!)
            req.timeoutInterval = 30
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let self = self, let data = data else { return }
                self.storeTrimmed(data)
                self.parse(data)
            }.resume()
        }
    }

    private func storeTrimmed(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let openai = root["openai"],
              let trimmed = try? JSONSerialization.data(withJSONObject: ["openai": openai]) else { return }
        try? trimmed.write(to: cacheURL, options: .atomic)
    }

    private func parse(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let openai = root["openai"] as? [String: Any],
              let models = openai["models"] as? [String: Any] else { return }
        var t: [String: (Double, Double, Double)] = [:]
        for (id, raw) in models {
            guard let m = raw as? [String: Any], let cost = m["cost"] as? [String: Any] else { continue }
            func n(_ v: Any?) -> Double? {
                if let x = v as? NSNumber { return x.doubleValue }
                if let x = v as? Double { return x }
                return nil
            }
            guard let inp = n(cost["input"]), let out = n(cost["output"]) else { continue }
            t[id] = (inp, out, n(cost["cache_read"]) ?? inp)
        }
        if !t.isEmpty { table = t; version += 1; logLine("pricing loaded: \(t.count) openai models") }
    }

    func price(for model: String) -> (input: Double, output: Double, cacheRead: Double)? {
        if let p = table[model] { return p }
        var best: String? = nil
        for key in table.keys where model.hasPrefix(key) {
            if best == nil || key.count > best!.count { best = key }
        }
        if let b = best, let p = table[b] { return p }
        if model.contains("codex"), let p = table["gpt-5-codex"] { return p }
        if model.hasPrefix("gpt-5"), let p = table["gpt-5"] { return p }
        return nil
    }
}

final class CodexStats {
    private let pricing = PricingTable()
    private var fileCache: [String: (mtime: TimeInterval, size: Int, days: [String: DayStat])] = [:]
    private var lastPricingVersion = -1
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private func codexHome() -> URL {
        if let e = ProcessInfo.processInfo.environment["CODEX_HOME"], !e.isEmpty {
            return URL(fileURLWithPath: e)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    private func candidateFiles() -> [URL] {
        let fm = FileManager.default
        let home = codexHome()
        var files: [URL] = []
        let cal = Calendar.current
        let sessions = home.appendingPathComponent("sessions")
        for back in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
                for name in names where name.hasSuffix(".jsonl") {
                    files.append(dir.appendingPathComponent(name))
                }
            }
        }
        let archived = home.appendingPathComponent("archived_sessions")
        if let names = try? fm.contentsOfDirectory(atPath: archived.path) {
            for name in names where name.hasSuffix(".jsonl") {
                let url = archived.appendingPathComponent(name)
                if let attrs = try? fm.attributesOfItem(atPath: url.path),
                   let mtime = attrs[.modificationDate] as? Date,
                   Date().timeIntervalSince(mtime) < 8 * 24 * 3600 {
                    files.append(url)
                }
            }
        }
        return files
    }

    private func forEachLine(in url: URL, _ body: (String) -> Void) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        var buffer = Data()
        while true {
            let chunk = h.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                if let s = String(data: lineData, encoding: .utf8) { body(s) }
            }
        }
        if !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8) { body(s) }
    }

    private func parseFile(_ file: URL, todayKey: String) -> [String: DayStat] {
        var days: [String: DayStat] = [:]
        var model = ""
        forEachLine(in: file) { line in
            guard line.contains("\"token_count\"") || line.contains("\"turn_context\"") else { return }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { return }
            let type = obj["type"] as? String
            if type == "turn_context", let m = payload["model"] as? String {
                model = m; return
            }
            guard type == "event_msg", payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { return }
            func iv(_ v: Any?) -> Int {
                if let n = v as? NSNumber { return n.intValue }
                if let i = v as? Int { return i }
                return 0
            }
            let input = iv(last["input_tokens"])
            let cached = iv(last["cached_input_tokens"])
            let output = iv(last["output_tokens"])
            let total = iv(last["total_tokens"]) > 0 ? iv(last["total_tokens"]) : input + output
            guard total > 0 else { return }
            var dayKey = todayKey
            if let ts = obj["timestamp"] as? String,
               let date = isoFrac.date(from: ts) ?? isoPlain.date(from: ts) {
                dayKey = dayFmt.string(from: date)
            }
            var stat = days[dayKey] ?? DayStat()
            stat.tokens += total
            let useModel = (info["model"] as? String) ?? model
            if let p = pricing.price(for: useModel) {
                let nonCached = max(0, input - cached)
                stat.cost += (Double(nonCached) * p.input + Double(cached) * p.cacheRead + Double(output) * p.output) / 1e6
            } else {
                stat.unpricedTokens += total
            }
            days[dayKey] = stat
        }
        return days
    }

    // completion: (today, trailing7Days) on an arbitrary queue.
    func compute(completion: @escaping (DayStat, DayStat) -> Void) {
        pricing.ensureLoaded()
        DispatchQueue.global(qos: .utility).async { [self] in
            if pricing.version != lastPricingVersion {
                fileCache = [:]
                lastPricingVersion = pricing.version
            }
            let fm = FileManager.default
            let todayKey = dayFmt.string(from: Date())
            var byDay: [String: DayStat] = [:]
            for file in candidateFiles() {
                let days: [String: DayStat]
                if let attrs = try? fm.attributesOfItem(atPath: file.path),
                   let mtime = attrs[.modificationDate] as? Date,
                   let size = attrs[.size] as? NSNumber {
                    let key = file.path
                    let mt = mtime.timeIntervalSince1970
                    if let hit = fileCache[key], hit.mtime == mt, hit.size == size.intValue {
                        days = hit.days
                    } else {
                        days = parseFile(file, todayKey: todayKey)
                        fileCache[key] = (mt, size.intValue, days)
                    }
                } else {
                    days = parseFile(file, todayKey: todayKey)
                }
                for (day, s) in days {
                    var agg = byDay[day] ?? DayStat()
                    agg.tokens += s.tokens; agg.cost += s.cost; agg.unpricedTokens += s.unpricedTokens
                    byDay[day] = agg
                }
            }
            var last7 = DayStat()
            let cal = Calendar.current
            for back in 0..<7 {
                if let day = cal.date(byAdding: .day, value: -back, to: Date()),
                   let s = byDay[dayFmt.string(from: day)] {
                    last7.tokens += s.tokens; last7.cost += s.cost; last7.unpricedTokens += s.unpricedTokens
                }
            }
            completion(byDay[todayKey] ?? DayStat(), last7)
        }
    }
}

func newestCodexActivity() -> Date? {
    let fm = FileManager.default
    let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    let cal = Calendar.current
    var newest: Date? = nil
    func consider(_ url: URL) {
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let mtime = attrs[.modificationDate] as? Date {
            if newest == nil || mtime > newest! { newest = mtime }
        }
    }
    let sessions = home.appendingPathComponent("sessions")
    for back in 0..<2 {
        guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
        let c = cal.dateComponents([.year, .month, .day], from: day)
        let dir = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            for name in names where name.hasSuffix(".jsonl") { consider(dir.appendingPathComponent(name)) }
        }
    }
    let archived = home.appendingPathComponent("archived_sessions")
    if let names = try? fm.contentsOfDirectory(atPath: archived.path) {
        for name in names where name.hasSuffix(".jsonl") { consider(archived.appendingPathComponent(name)) }
    }
    return newest
}
