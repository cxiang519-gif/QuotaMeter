import AppKit
import UserNotifications
import WebKit

// QuotaMeter: tiny menu bar meter for Codex + Muse (muse.ai) quotas.
// - Muse: POST muse.ai fetchSubscriptionAction with a manually pasted Cookie
//   header (same protocol as the public CodexBar museai plugin, reimplemented).
//   The usage API is percent-only; no absolute Muse token/cost figures exist.
// - Codex: GET chatgpt.com/backend-api/wham/usage + /wham/rate-limit-reset-credits
//   with the Codex CLI OAuth token from ~/.codex/auth.json (read-only).
// - Codex token/cost stats come from local session logs (see stats.swift).
// - Codex item: shows the 5h session window; hovering swaps it to the weekly
//   window (ring + numbers). Panels use bars, and close on any outside click.
// - Notifications: reset credits expiring (3d/1d), any window under 15%,
//   and window resets. Codex panel predicts time-to-exhaustion while active.
// - Muse: a second account (qm_cookie2) can be monitored too; hovering the
//   M item swaps the ring between accounts, the panel lists both.
// - Conversation shortcuts live in shortcuts.swift (user-picked links).
// - Codex panel can ping with "你好" to anchor each new 5h window early:
//   API first (raw POST /backend-api/codex/responses with the CLI OAuth
//   token and the cheapest catalog model, ~16 tokens), falling back to
//   codex exec resume into a chosen thread. Weekly remaining under 10%
//   skips the auto ping.
// Secrets are never logged. The Muse cookie lives only in UserDefaults.

let kCookieKey = "qm_cookie"
let kActionKey = "qm_action_id"
let kCookie2Key = "qm_cookie2"
let kUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
let kOrigin = "https://muse.ai"

func logLine(_ s: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    let file = dir.appendingPathComponent("quotameter.log")
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "[\(df.string(from: Date()))] \(s)\n"
    if let h = try? FileHandle(forWritingTo: file) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: file, atomically: true, encoding: .utf8)
    }
}

func regexFirst(_ pattern: String, in text: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let m = re.firstMatch(in: text, range: range) else { return nil }
    var groups: [String] = []
    for i in 0..<m.numberOfRanges {
        if let r = Range(m.range(at: i), in: text) { groups.append(String(text[r])) } else { groups.append("") }
    }
    return groups
}

func regexAll(_ pattern: String, in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return re.matches(in: text, range: range).compactMap { m in
        Range(m.range, in: text).map { String(text[$0]) }
    }
}

func numVal(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    return nil
}

func parseDateVal(_ v: Any?) -> Date? {
    if let n = numVal(v) { return Date(timeIntervalSince1970: n) }
    if let s = v as? String {
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
    return nil
}

func compactCountdown(_ interval: TimeInterval) -> String {
    if interval <= 0 { return "0m" }
    let totalMin = Int(interval) / 60
    let d = totalMin / 1440, h = (totalMin % 1440) / 60, m = totalMin % 60
    if d > 0 { return "\(d)d\(h)h" }
    if h > 0 { return "\(h)h\(m)m" }
    return "\(m)m"
}

func fmtTokens(_ n: Int) -> String {
    if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1e9) }
    if n >= 1_000_000 { return String(format: "%.0fM", Double(n) / 1e6) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
    return "\(n)"
}

func fmtMoney(_ v: Double) -> String { String(format: "$%.2f", v) }

func fmtReset(_ date: Date) -> String {
    let df = DateFormatter()
    df.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
    return df.string(from: date)
}

func fmtDay(_ date: Date) -> String {
    let df = DateFormatter(); df.dateFormat = "M月d日"
    return df.string(from: date)
}

/// The original app icon for a bundle id, menu-bar sized. Falls back to a
/// tinted symbol when the app is not installed.
func appIconImage(bundleIds: [String], fallbackSymbol: String) -> NSImage {
    for bid in bundleIds {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let icon = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage)
                ?? NSWorkspace.shared.icon(forFile: url.path)
            return icon
        }
    }
    if let s = ringSymbolImage(fallbackSymbol, pointSize: 14, color: .labelColor) { return s }
    return NSImage()
}

/// The menu-bar look: the original app icon clipped into the middle of
/// the remaining-amount ring. The icon is a full-colour image, so it reads
/// as a separate layer from the thin arc instead of blurring into it the
/// way a line-glyph did.
func ringIconImage(remaining: Double?, icon: NSImage) -> NSImage {
    let size: CGFloat = 22
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let center = NSPoint(x: size / 2, y: size / 2)
        let lw: CGFloat = 2.2
        let radius = size / 2 - lw / 2 - 0.5
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lw
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setStroke()
        track.stroke()
        if let r = remaining {
            let frac = max(0, min(1, r / 100))
            if frac > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * frac, clockwise: true)
                arc.lineWidth = lw
                arc.lineCapStyle = .round
                (frac < 0.10 ? NSColor.systemRed : (frac < 0.25 ? NSColor.systemOrange : NSColor.systemTeal)).setStroke()
                arc.stroke()
            }
        }
        let d: CGFloat = 13
        let rect = NSRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: rect).addClip()
        icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
    img.isTemplate = false
    return img
}

/// Tinted SF Symbol glyph drawn in the middle of a menu-bar ring.
func ringSymbolImage(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
    guard let sym = base.withSymbolConfiguration(cfg) else { return nil }
    let out = NSImage(size: sym.size, flipped: false) { rect in
        sym.draw(in: rect)
        color.setFill()
        rect.fill(using: .sourceAtop)
        return true
    }
    return out
}

func ringImage(remaining: Double?, symbol: String, size: CGFloat = 16) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let lineWidth: CGFloat = 2.2
        let inset = lineWidth / 2 + 0.5
        let circleRect = rect.insetBy(dx: inset, dy: inset)
        NSColor.tertiaryLabelColor.setStroke()
        let bg = NSBezierPath(ovalIn: circleRect); bg.lineWidth = lineWidth; bg.stroke()
        if let r = remaining {
            let frac = max(0, min(1, r / 100))
            if frac > 0 {
                let color: NSColor = r < 10 ? .systemRed : (r < 25 ? .systemOrange : .systemTeal)
                color.setStroke()
                let arc = NSBezierPath()
                let center = NSPoint(x: rect.midX, y: rect.midY)
                let radius = (rect.width - lineWidth) / 2 - 0.5
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - CGFloat(frac) * 360, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                arc.stroke()
            }
        }
        if let s = ringSymbolImage(symbol, pointSize: size * 0.52, color: .labelColor) {
            let ts = s.size
            s.draw(in: NSRect(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2, width: ts.width, height: ts.height))
        }
        return true
    }
    img.isTemplate = false
    return img
}

// MARK: - Bar UI (popover visualization)

final class BarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var tint: NSColor = .systemTeal { didSet { needsDisplay = true } }
    override func draw(_ dirty: NSRect) {
        let r = bounds
        guard r.height > 0 else { return }
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.tertiaryLabelColor.setFill(); track.fill()
        let w = r.width * CGFloat(max(0, min(1, fraction)))
        if w > 0.5 {
            let fr = NSRect(x: 0, y: 0, width: max(w, r.height), height: r.height)
            let fill = NSBezierPath(roundedRect: fr, xRadius: r.height / 2, yRadius: r.height / 2)
            tint.setFill(); fill.fill()
        }
    }
}

final class BarRow: NSView {
    private let titleL = NSTextField(labelWithString: "")
    private let pctL = NSTextField(labelWithString: "")
    private let bar = BarView()
    private let subL = NSTextField(labelWithString: "")
    init(width: CGFloat = 252) {
        super.init(frame: .zero)
        titleL.font = .systemFont(ofSize: 11.5, weight: .medium)
        pctL.font = .monospacedDigitSystemFont(ofSize: 15.5, weight: .semibold)
        pctL.alignment = .right
        subL.font = .systemFont(ofSize: 10.5)
        subL.textColor = .secondaryLabelColor
        for v in [titleL, pctL, bar, subL] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            titleL.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleL.topAnchor.constraint(equalTo: topAnchor),
            pctL.trailingAnchor.constraint(equalTo: trailingAnchor),
            pctL.topAnchor.constraint(equalTo: topAnchor),
            pctL.leadingAnchor.constraint(greaterThanOrEqualTo: titleL.trailingAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: titleL.bottomAnchor, constant: 9),
            bar.heightAnchor.constraint(equalToConstant: 6),
            subL.leadingAnchor.constraint(equalTo: leadingAnchor),
            subL.trailingAnchor.constraint(equalTo: trailingAnchor),
            subL.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 3),
            subL.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func setData(title: String, remaining: Double?, sub: String) {
        titleL.stringValue = title
        if let r = remaining {
            pctL.stringValue = "\(Int(r.rounded()))%"
            bar.fraction = r / 100
            bar.tint = r < 10 ? .systemRed : (r < 25 ? .systemOrange : .systemTeal)
        } else {
            pctL.stringValue = "--"
            bar.fraction = 0
        }
        subL.stringValue = sub
    }
}

final class HoverTracker: NSResponder {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

// MARK: - Muse (muse.ai)

/// Minimal sparkline: a soft-filled polyline, normalized to a fixed
/// ceiling when one is set, otherwise to the series maximum.
final class SparkView: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var ceiling: Double? = nil { didSet { needsDisplay = true } }
    var color: NSColor = .systemBlue { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let b = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setStroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: b.minX, y: b.minY))
        base.line(to: NSPoint(x: b.maxX, y: b.minY))
        base.lineWidth = 0.5
        base.stroke()
        guard values.count >= 2 else { return }
        let hi = max(ceiling ?? (values.max() ?? 1), 0.0001)
        let stepX = b.width / CGFloat(values.count - 1)
        let line = NSBezierPath()
        for (i, v) in values.enumerated() {
            let y = b.minY + b.height * CGFloat(min(max(v / hi, 0), 1))
            let p = NSPoint(x: b.minX + stepX * CGFloat(i), y: y)
            if i == 0 { line.move(to: p) } else { line.line(to: p) }
        }
        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: b.maxX, y: b.minY))
        fill.line(to: NSPoint(x: b.minX, y: b.minY))
        fill.close()
        color.withAlphaComponent(0.15).setFill()
        fill.fill()
        color.setStroke()
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        line.stroke()
    }
}

/// Slim stacked bar at the top of a Top-5 column: segments are shares of
/// the column's real total, the empty track is the rest. No text needed.
final class ShareStripView: NSView {
    var segments: [(frac: Double, color: NSColor)] = [] { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let r = bounds
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.3).setFill()
        track.fill()
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        var x = r.minX
        for s in segments {
            let w = r.width * CGFloat(min(max(s.frac, 0), 1))
            if w <= 0 { continue }
            s.color.setFill()
            NSRect(x: x, y: r.minY, width: w, height: r.height).fill()
            x += w
            if x >= r.maxX { break }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Bottom-right corner grip: drag resizes the system panel, double-click
/// restores the default width. Reports screen-space drag deltas.
final class ResizeGripView: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    private var startX: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Embossed diagonal lines: a light pass offset up-left, then the
        // main pass in label color, so the grip reads on any background.
        for pass in 0..<2 {
            if pass == 0 {
                NSColor.white.withAlphaComponent(0.4).setStroke()
            } else {
                NSColor.labelColor.withAlphaComponent(0.5).setStroke()
            }
            let d: CGFloat = pass == 0 ? 0.8 : 0
            for i in 0..<4 {
                let o = CGFloat(i) * 4
                let p = NSBezierPath()
                p.move(to: NSPoint(x: bounds.maxX - 2 - o + d, y: bounds.minY + 2 - d))
                p.line(to: NSPoint(x: bounds.maxX - 2 + d, y: bounds.minY + 2 + o - d))
                p.lineWidth = 1.7
                p.lineCapStyle = .round
                p.stroke()
            }
        }
    }
    override func resetCursorRects() {
        if #available(macOS 15.0, *) {
            addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(); return }
        startX = NSEvent.mouseLocation.x
        onBegin?()
    }
    override func mouseDragged(with event: NSEvent) {
        onDrag?(NSEvent.mouseLocation.x - startX)
    }
    override func mouseUp(with event: NSEvent) {
        onEnd?()
    }
}

/// Label whose tooltip always mirrors its full text, so anything the
/// layout truncates with an ellipsis stays readable on hover.
final class TipTextField: NSTextField {
    override var stringValue: String {
        didSet { toolTip = stringValue }
    }

    /// True when the (single-line, truncating) text is currently clipped.
    var isClipped: Bool {
        guard bounds.width > 0, !stringValue.isEmpty else { return false }
        guard let full = cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)) else { return false }
        return full.width > bounds.width + 1
    }

    private var expandedWrap = false

    /// Click a clipped label to expand it in place (word wrap, full
    /// text); click again to collapse. Hover tooltips proved unreliable
    /// in the user's environment, so clicking is the guaranteed path.
    /// Fields that already wrap (e.g. the multi-line history) ignore it.
    override func mouseDown(with event: NSEvent) {
        guard expandedWrap || (lineBreakMode == .byTruncatingTail && isClipped) else {
            super.mouseDown(with: event)
            return
        }
        expandedWrap.toggle()
        if expandedWrap {
            lineBreakMode = .byWordWrapping
            maximumNumberOfLines = 0
        } else {
            lineBreakMode = .byTruncatingTail
            maximumNumberOfLines = 1
        }
        NotificationCenter.default.post(name: Notification.Name("qmTextWrapToggled"), object: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
    static func makeLabel(_ s: String) -> TipTextField {
        let f = TipTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.isEditable = false
        f.isSelectable = false
        f.stringValue = s
        return f
    }
}

struct ClaudeUsage {
    var percentUsed: Double
    var resetsAt: Date?
    var tokensLeftText: String?
    var topupText: String?
    var topupExpiry: Date?
    var topupUsedPct: Double?
    var remaining: Double { max(0, 100 - percentUsed) }
}

enum ClaudeOutcome {
    case ok(ClaudeUsage)
    case noCookie
    case signedOut
    case failed(String)
}

final class RedirectRecorder: NSObject, URLSessionTaskDelegate {
    var locations: [String] = []
    func reset() { locations = [] }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let u = request.url?.absoluteString { locations.append(u) }
        completionHandler(request)
    }
}

final class ClaudeClient {
    private let recorder = RedirectRecorder()
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpCookieStorage = nil
        return URLSession(configuration: cfg, delegate: recorder, delegateQueue: nil)
    }()
    private let cookieKey: String
    init(cookieKey: String = kCookieKey) { self.cookieKey = cookieKey }
    var cookie: String { UserDefaults.standard.string(forKey: cookieKey) ?? "" }

    private func request(url: String, method: String, headers: [String: String], body: Data?, completion: @escaping (Int, String) -> Void) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        session.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            completion(status, text)
        }.resume()
    }

    private func signedOut(status: Int) -> Bool {
        if status == 401 || status == 403 { return true }
        return recorder.locations.contains { $0.hasPrefix("https://auth.muse.ai/") }
    }

    private func chunkPaths(_ text: String) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for m in regexAll("static/chunks/[\\w~.-]+\\.js", in: text) {
            let p = "/_next/" + m
            if seen.insert(p).inserted { out.append(p) }
        }
        return out
    }

    private func fetchChunks(_ paths: [String], completion: @escaping ([String]) -> Void) {
        var results = [String](repeating: "", count: paths.count)
        let group = DispatchGroup()
        for (i, p) in paths.enumerated() {
            group.enter()
            request(url: kOrigin + p, method: "GET", headers: ["Accept": "*/*", "User-Agent": kUA], body: nil) { status, text in
                if status == 200 { results[i] = text }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(results) }
    }

    private func discover(completion: @escaping (String?) -> Void) {
        recorder.reset()
        request(url: kOrigin + "/", method: "GET", headers: ["Cookie": cookie, "Accept": "text/html", "User-Agent": kUA], body: nil) { [self] status, pageText in
            if signedOut(status: status) { completion(nil); return }
            guard status == 200 else { completion(""); return }
            let paths = Array(chunkPaths(pageText).prefix(96))
            discoverInChunks(paths: paths, index: 0, accumulated: "", completion: completion)
        }
    }

    private func discoverInChunks(paths: [String], index: Int, accumulated: String, completion: @escaping (String?) -> Void) {
        if accumulated.count > 8 * 1024 * 1024 { completion(""); return }
        if index >= paths.count { completion(""); return }
        let batch = Array(paths[index..<min(index + 8, paths.count)])
        fetchChunks(batch) { [self] texts in
            let text = accumulated + "\n" + texts.joined(separator: "\n")
            if let module = regexFirst("\\.A\\((\\d+)\\)\\.then\\(\\(\\{[^}]*Settings", in: text)?[1],
               let loader = regexFirst("[,{\\[]\(module),\\w+=>\\{\\w+\\.v\\(\\w+=>Promise\\.all\\(\\[([^\\]]*)", in: text)?[1] {
                let settingsPaths = Array(chunkPaths(loader).prefix(32))
                findActionID(paths: settingsPaths, index: 0, completion: completion)
            } else {
                discoverInChunks(paths: paths, index: index + 8, accumulated: text, completion: completion)
            }
        }
    }

    private func findActionID(paths: [String], index: Int, completion: @escaping (String?) -> Void) {
        if index >= paths.count { completion(""); return }
        let batch = Array(paths[index..<min(index + 8, paths.count)])
        fetchChunks(batch) { [self] texts in
            for body in texts {
                if let id = regexFirst("\"([0-9a-f]{40,})\",[^\"]{0,200}\"fetchSubscriptionAction\"", in: body)?[1] {
                    completion(id); return
                }
            }
            findActionID(paths: paths, index: index + 8, completion: completion)
        }
    }

    private func post(actionID: String, completion: @escaping (Int, String) -> Void) {
        recorder.reset()
        let body = "[{\"includeAgreement\":true}]".data(using: .utf8)
        request(url: kOrigin + "/", method: "POST", headers: [
            "Cookie": cookie,
            "Content-Type": "application/json",
            "Accept": "text/x-component",
            "Next-Action": actionID,
            "Origin": kOrigin,
            "Sec-Fetch-Site": "same-origin",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty",
            "User-Agent": kUA,
        ], body: body, completion: completion)
    }

    private func isStale(status: Int, body: String) -> Bool {
        status == 404 && body.lowercased().contains("server action not found")
    }

    func fetchUsage(completion: @escaping (ClaudeOutcome) -> Void) {
        guard !cookie.isEmpty else { completion(.noCookie); return }
        let stored = UserDefaults.standard.string(forKey: kActionKey)
        if let id = stored, !id.isEmpty {
            post(actionID: id) { [self] status, body in
                if isStale(status: status, body: body) {
                    UserDefaults.standard.removeObject(forKey: kActionKey)
                    discoverAndPost(completion: completion)
                } else if signedOut(status: status) {
                    completion(.signedOut)
                } else {
                    finish(status: status, body: body, completion: completion)
                }
            }
        } else {
            discoverAndPost(completion: completion)
        }
    }

    private func discoverAndPost(completion: @escaping (ClaudeOutcome) -> Void) {
        discover { [self] id in
            guard let id = id else { completion(.signedOut); return }
            guard !id.isEmpty else { completion(.failed("找不到订阅接口，站点可能改版")); return }
            post(actionID: id) { [self] status, body in
                if isStale(status: status, body: body) { completion(.failed("订阅接口已变更")); return }
                if signedOut(status: status) { completion(.signedOut); return }
                UserDefaults.standard.set(id, forKey: kActionKey)
                finish(status: status, body: body, completion: completion)
            }
        }
    }

    private func finish(status: Int, body: String, completion: @escaping (ClaudeOutcome) -> Void) {
        guard status == 200 else { completion(.failed("HTTP \(status)")); return }
        guard let usage = parse(body) else { completion(.failed("返回内容无法解析")); return }
        completion(.ok(usage))
    }

    private func tokensLeft(_ label: String?) -> String? {
        guard let label = label else { return nil }
        return regexFirst("\\(([^()]+ tokens left)\\)", in: label)?[1]
    }

    private func parse(_ body: String) -> ClaudeUsage? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let jsonText = regexFirst("^[0-9a-f]+:(\\{.*\\})\\s*$", in: String(line))?[1],
                  let data = jsonText.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (row["success"] as? NSNumber)?.boolValue == true,
                  let sub = row["subscription"] as? [String: Any],
                  let usageDict = sub["usage"] as? [String: Any],
                  let pct = numVal(usageDict["percentUsed"]) else { continue }
            var u = ClaudeUsage(percentUsed: min(100, max(0, pct)))
            if let ts = numVal(usageDict["resetsAt"]) { u.resetsAt = Date(timeIntervalSince1970: ts) }
            u.tokensLeftText = tokensLeft(sub["usageRowValueLabel"] as? String)
            if let bal = numVal(sub["topupBalance"]), let tot = numVal(sub["topupTotal"]), tot > 0 {
                let value = tokensLeft(sub["topupRowValueLabel"] as? String)
                    ?? (sub["topupRowValueLabel"] as? String)
                    ?? String(format: "$%.2f left", bal / 1e6)
                u.topupText = "\(sub["topupRowLabel"] as? String ?? "额外额度")：\(value)"
                u.topupUsedPct = (1 - bal / tot) * 100
            }
            var topupExp: Date? = nil
            var anyExp: Date? = nil
            for (k, v) in sub where k.lowercased().contains("expir") {
                guard let d = parseDateVal(v) else { continue }
                if k.lowercased().contains("topup") { topupExp = d } else if anyExp == nil { anyExp = d }
            }
            u.topupExpiry = topupExp ?? (u.topupText != nil ? anyExp : nil)
            return u
        }
        return nil
    }
}

// MARK: - Codex (chatgpt.com wham/usage + rate-limit-reset-credits, auth from ~/.codex/auth.json)

struct CodexUsage {
    var sessionUsed: Double?; var sessionReset: Date?
    var weeklyUsed: Double?; var weeklyReset: Date?
    var sessionRemaining: Double? { sessionUsed.map { max(0, 100 - $0) } }
    var weeklyRemaining: Double? { weeklyUsed.map { max(0, 100 - $0) } }
}

struct ResetCredit {
    var status: String
    var expiresAt: Date?
}

enum CodexOutcome {
    case ok(CodexUsage)
    case noAuth
    case expired
    case failed(String)
}

final class CodexClient {
    private func codexHome() -> URL {
        if let e = ProcessInfo.processInfo.environment["CODEX_HOME"], !e.isEmpty {
            return URL(fileURLWithPath: e)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    private func loadAuth() -> (token: String, accountId: String?)? {
        let url = codexHome().appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let at = tokens["access_token"] as? String, !at.isEmpty else { return nil }
        return (at, tokens["account_id"] as? String)
    }

    /// Token access for the ping's raw API call (same read-only auth file).
    func pingAuth() -> (token: String, accountId: String?)? { loadAuth() }

    private func authedRequest(_ urlString: String) -> URLRequest? {
        guard let auth = loadAuth() else { return nil }
        var req = URLRequest(url: URL(string: urlString)!)
        req.timeoutInterval = 30
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        if let aid = auth.accountId { req.setValue(aid, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(kUA, forHTTPHeaderField: "User-Agent")
        return req
    }

    func fetchUsage(completion: @escaping (CodexOutcome) -> Void) {
        guard let req = authedRequest("https://chatgpt.com/backend-api/wham/usage") else {
            completion(.noAuth); return
        }
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { completion(.expired); return }
            guard status == 200, let data = data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failed("HTTP \(status)")); return
            }
            completion(.ok(Self.parse(root)))
        }.resume()
    }

    func fetchResetCredits(completion: @escaping ([ResetCredit]?) -> Void) {
        guard let req = authedRequest("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits") else {
            completion(nil); return
        }
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data = data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = root["credits"] as? [[String: Any]] else {
                completion(nil); return
            }
            let credits = list.map { c in
                ResetCredit(status: (c["status"] as? String) ?? "",
                            expiresAt: parseDateVal(c["expires_at"]))
            }
            completion(credits)
        }.resume()
    }

    private static func parse(_ root: [String: Any]) -> CodexUsage {
        var u = CodexUsage()
        guard let rl = root["rate_limit"] as? [String: Any] else { return u }
        struct W { var seconds: Double; var used: Double; var reset: Date? }
        func window(_ v: Any?) -> W? {
            guard let d = v as? [String: Any], let used = numVal(d["used_percent"]) else { return nil }
            let secs = numVal(d["limit_window_seconds"]) ?? 0
            let reset = numVal(d["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            return W(seconds: secs, used: used, reset: reset)
        }
        let primary = window(rl["primary_window"])
        let secondary = window(rl["secondary_window"])
        var windows = [primary, secondary].compactMap { $0 }
        if windows.count == 2 {
            windows.sort { $0.seconds < $1.seconds }
            u.sessionUsed = windows[0].used; u.sessionReset = windows[0].reset
            u.weeklyUsed = windows[1].used; u.weeklyReset = windows[1].reset
        } else if let w = windows.first {
            if w.seconds > 86400 { u.weeklyUsed = w.used; u.weeklyReset = w.reset }
            else { u.sessionUsed = w.used; u.sessionReset = w.reset }
        } else {
            if let p = primary { u.sessionUsed = p.used; u.sessionReset = p.reset }
            if let s = secondary { u.weeklyUsed = s.used; u.weeklyReset = s.reset }
        }
        return u
    }
}

// MARK: - Cookie window

final class CookieWindowController: NSWindowController {
    private let tv1 = NSTextView()
    private let tv2 = NSTextView()
    private let nf1 = NSTextField()
    private let nf2 = NSTextField()
    private let seg1 = NSSegmentedControl(labels: ["应用", "网页"], trackingMode: .selectOne, target: nil, action: nil)
    private let seg2 = NSSegmentedControl(labels: ["应用", "网页"], trackingMode: .selectOne, target: nil, action: nil)
    var onSave: ((String, String, String, String) -> Void)?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Muse 账号设置"
        window.backgroundColor = .underPageBackgroundColor
        self.init(window: window)
        window.center()

        let hint = NSTextField(wrappingLabelWithString: "Cookie 从浏览器开发者工具里复制，只存本机。账号 2 的 Cookie 要在登录着账号 2 的浏览器里复制。")
        hint.font = NSFont.systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            hint,
            section(header: "账号 1", card: accountCard(nameField: nf1, seg: seg1, tv: tv1,
                        nameKey: "qm_claude_name1", surfaceKey: "qm_claude_surface1", defaultSurface: "app")),
            section(header: "账号 2", card: accountCard(nameField: nf2, seg: seg2, tv: tv2,
                        nameKey: "qm_claude_name2", surfaceKey: "qm_claude_surface2", defaultSurface: "web")),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded
        let saveBtn = NSButton(title: "保存", target: self, action: #selector(saveClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let btnRow = NSStackView(views: [spacer, cancelBtn, saveBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        btnRow.translatesAutoresizingMaskIntoConstraints = false

        guard let content = window.contentView else { return }
        content.addSubview(stack)
        content.addSubview(btnRow)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            btnRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            btnRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            btnRow.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
            btnRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        for v in stack.arrangedSubviews.dropFirst() {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        content.layoutSubtreeIfNeeded()
        let fitHeight = stack.fittingSize.height + 16 + 30 + 36
        window.setContentSize(NSSize(width: 460, height: fitHeight))
    }

    /// A System-Settings-style section: small bold header above the card.
    private func section(header: String, card: NSView) -> NSStackView {
        let head = NSTextField(labelWithString: header)
        head.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        let s = NSStackView(views: [head, card])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 7
        card.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        return s
    }

    private func hairline() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func row(label text: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let gap = NSView()
        gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        gap.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, gap, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    /// One account as a rounded card: label-left / control-right rows with
    /// hairline dividers, and the Cookie text in an inset well — the shape
    /// of a System Settings pane.
    private func accountCard(nameField: NSTextField, seg: NSSegmentedControl,
                             tv: NSTextView, nameKey: String, surfaceKey: String,
                             defaultSurface: String) -> NSView {
        nameField.placeholderString = "可留空"
        nameField.stringValue = UserDefaults.standard.string(forKey: nameKey) ?? ""
        nameField.widthAnchor.constraint(equalToConstant: 230).isActive = true
        let nameRow = row(label: "名称", control: nameField)

        seg.selectedSegment = (UserDefaults.standard.string(forKey: surfaceKey) ?? defaultSurface) == "web" ? 1 : 0
        let openRow = row(label: "打开方式", control: seg)

        let cookieLabel = NSTextField(labelWithString: "Cookie")
        cookieLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        cookieLabel.textColor = .secondaryLabelColor
        let cookieHint = NSTextField(labelWithString: "留空表示不改")
        cookieHint.font = NSFont.systemFont(ofSize: 11)
        cookieHint.textColor = .tertiaryLabelColor
        let cookieGap = NSView()
        cookieGap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cookieGap.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cookieRow = NSStackView(views: [cookieLabel, cookieGap, cookieHint])
        cookieRow.orientation = .horizontal
        cookieRow.spacing = 8

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 5, height: 5)
        tv.drawsBackground = false
        scroll.documentView = tv
        let well = NSView()
        well.wantsLayer = true
        well.layer?.cornerRadius = 8
        well.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        well.layer?.borderWidth = 0.5
        well.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -2),
            scroll.topAnchor.constraint(equalTo: well.topAnchor, constant: 2),
            scroll.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -2),
            well.heightAnchor.constraint(equalToConstant: 62),
        ])

        let inner = NSStackView(views: [nameRow, hairline(), openRow, hairline(), cookieRow, well])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 10
        inner.translatesAutoresizingMaskIntoConstraints = false
        for v in [nameRow, openRow, cookieRow, well] {
            v.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        for v in inner.arrangedSubviews where v is NSBox {
            v.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        return card
    }

    @objc private func saveClicked() {
        UserDefaults.standard.set(seg1.selectedSegment == 1 ? "web" : "app", forKey: "qm_claude_surface1")
        UserDefaults.standard.set(seg2.selectedSegment == 1 ? "web" : "app", forKey: "qm_claude_surface2")
        onSave?(tv1.string.trimmingCharacters(in: .whitespacesAndNewlines),
                tv2.string.trimmingCharacters(in: .whitespacesAndNewlines),
                nf1.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                nf2.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        window?.close()
    }

    @objc private func cancelClicked() { window?.close() }
}

// MARK: - Muse web window

/// Opens muse.ai as one specific account: the account's own cookies (the
/// same ones pasted for monitoring) are injected into a per-account
/// persistent web store, so the page always lands on exactly the chosen
/// account — no browser profile has to be logged in correctly first.
final class ClaudeWebWindowController: NSWindowController {
    private let webView: WKWebView
    let cookieStamp: String

    init(cookies: [HTTPCookie], stamp: String, slot: Int) {
        cookieStamp = stamp
        let key = "qm_webstore_\(slot + 1)"
        let idString = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
        UserDefaults.standard.set(idString, forKey: key)
        let config = WKWebViewConfiguration()
        if let uuid = UUID(uuidString: idString) {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: uuid)
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1080, height: 760), configuration: config)
        webView.customUserAgent = kUA
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.contentView = webView
        super.init(window: window)
        window.center()
        let store = config.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for c in cookies { group.enter(); store.setCookie(c) { group.leave() } }
        group.notify(queue: .main) { [weak self] in
            self?.webView.load(URLRequest(url: URL(string: "https://muse.ai/")!))
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Ping thread picker

final class PingThreadPickerController: NSWindowController {
    var onPick: ((String, String) -> Void)?
    var onCreate: (() -> Void)?
    private var entries: [(id: String, name: String, updated: Date)] = []
    convenience init(entries: [(id: String, name: String, updated: Date)]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "选择发送「你好」的对话"
        window.center()
        self.init(window: window)
        self.entries = entries
        let hint = NSTextField(wrappingLabelWithString: "点一个对话作为目标。以后手动和自动发送都发到这个对话里。")
        hint.frame = NSRect(x: 16, y: 372, width: 428, height: 36)
        window.contentView?.addSubview(hint)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: 428, height: 348))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        let df = DateFormatter(); df.dateFormat = "M月d日 HH:mm"
        let createBtn = NSButton(title: "＋ 新建专用对话（推荐，这个对话平时别在应用里打开）", target: self, action: #selector(pick(_:)))
        createBtn.bezelStyle = .rounded; createBtn.alignment = .left; createBtn.tag = -1
        createBtn.translatesAutoresizingMaskIntoConstraints = false
        createBtn.widthAnchor.constraint(equalToConstant: 396).isActive = true
        stack.addArrangedSubview(createBtn)
        for (i, e) in entries.enumerated() {
            let b = NSButton(title: "\(e.name)　·　\(df.string(from: e.updated))", target: self, action: #selector(pick(_:)))
            b.bezelStyle = .rounded; b.alignment = .left; b.tag = i
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 396).isActive = true
            stack.addArrangedSubview(b)
        }
        if entries.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: "没读到对话列表（~/.codex/session_index.jsonl）"))
        }
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 8),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -16),
        ])
        window.contentView?.addSubview(scroll)
    }
    @objc private func pick(_ sender: NSButton) {
        if sender.tag == -1 { onCreate?(); window?.close(); return }
        guard entries.indices.contains(sender.tag) else { return }
        let e = entries[sender.tag]
        onPick?(e.id, e.name)
        window?.close()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private let claudeClients = [ClaudeClient(cookieKey: kCookieKey), ClaudeClient(cookieKey: kCookie2Key)]
    private let codexClient = CodexClient()
    private let stats = CodexStats()

    private var codexItem: NSStatusItem!
    private var claudeItem: NSStatusItem!
    private let codexPopover = NSPopover()
    private let claudePopover = NSPopover()
    private let sysPopover = NSPopover()
    private var sysItem: NSStatusItem!
    private var sysPanelStack: NSStackView?
    private let sysMemBox = NSStackView()
    private let sysEnergyBox = NSStackView()
    private let sysSelf = TipTextField.makeLabel("")
    private var sysTimer: Timer?
    private var sysPrevGroups: [String: (energy: UInt64, cpu: UInt64, time: Date)] = [:]
    private var sysSelfPrev: (cpu: TimeInterval, time: Date)?
    private var selfIdlePrev: (cpuSec: Double, time: Date)?
    private var sysIconCache: [String: NSImage] = [:]
    private let sysCPUBox = NSStackView()
    private let sysTotals = NSTextField(labelWithString: "整机：…")
    private let sparkCPU = SparkView()
    private let sparkMem = SparkView()
    private let sparkEnergy = SparkView()
    private let stripMem = ShareStripView()
    private let stripCPU = ShareStripView()
    private let stripEnergy = ShareStripView()
    private var sysTotCPUFrac01: Double = 0
    private var sysMemUsedFrac01: Double = 0
    private var sysPinned = UserDefaults.standard.bool(forKey: "qm_sys_pin")
    private let sysPinBtn = NSButton()
    private let sysCapMem = TipTextField.makeLabel("")
    private let sysCapCPU = TipTextField.makeLabel("")
    private let sysCapEnergy = TipTextField.makeLabel("")
    private lazy var sysDesignMaxW: Double = computeDesignMaxW()
    private var sysPanelWidth: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "qm_sys_width")
        return (v >= 600 && v <= 900) ? CGFloat(v) : 798
    }()
    private var sysInnerW: [NSLayoutConstraint] = []
    private var sysColW: [NSLayoutConstraint] = []
    private var sysDragStartWidth: CGFloat?
    private func sysColWidth() -> CGFloat { (sysPanelWidth - 22 - 20) / 3 }
    private var histCPU: [(Date, Double)] = []
    private var histMem: [(Date, Double)] = []
    private var histEnergy: [(Date, Double)] = []
    private var prevCPUTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)?
    private let machFactor: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()
    private let codexHover = HoverTracker()
    private var codexHovering = false
    private var outsideClickMonitor: Any?

    private var codexUsage: CodexUsage?
    private var codexStatus = "尚未获取"
    private var codexCredits: [ResetCredit]?
    private var claudeUsages: [ClaudeUsage?] = [nil, nil]
    private var claudeStatuses = ["尚未获取", "尚未获取"]
    private func claudeSurface(_ i: Int) -> String {
        let def = i == 0 ? "app" : "web"
        return UserDefaults.standard.string(forKey: "qm_claude_surface\(i + 1)") ?? def
    }

    /// Parse a stored Cookie header into real cookies for muse.ai.
    private func museCookies(from raw: String) -> [HTTPCookie] {
        var out: [HTTPCookie] = []
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !kv[0].isEmpty else { continue }
            if let c = HTTPCookie(properties: [.domain: ".muse.ai", .path: "/", .name: kv[0], .value: kv[1]]) {
                out.append(c)
            }
        }
        return out
    }

    /// Pre-build the web window of every account whose open-mode is "web"
    /// (hidden, shortly after launch), so a click only has to show an
    /// already-loaded page instead of cold-starting a web view.
    private func prewarmWeb() {
        for i in 0...1 where hasCookie(i) && claudeSurface(i) == "web" {
            let raw = UserDefaults.standard.string(forKey: i == 0 ? kCookieKey : kCookie2Key) ?? ""
            if webWCs[i] == nil {
                webWCs[i] = ClaudeWebWindowController(cookies: museCookies(from: raw), stamp: raw, slot: i)
                webWCs[i]?.window?.title = "\(claudeName(i)) · Muse 网页"
                webStamps[i] = raw
                logLine("Muse webview prewarmed slot \(i + 1)")
            }
        }
    }

    @objc private func openClaudeRow1() { openClaudeSurface(slot: muRowSlot[0]) }
    @objc private func openClaudeRow2() { openClaudeSurface(slot: muRowSlot[1]) }

    /// Wake one account where it lives: the official app for "app" accounts,
    /// muse.ai in that account's own Chrome profile for "web" accounts.
    private func openClaudeSurface(slot i: Int) {
        if claudeSurface(i) == "app" {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.meta.endo") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                logLine("Muse open app (slot \(i + 1))")
            } else {
                logLine("Muse app not found")
            }
            return
        }
        let raw = UserDefaults.standard.string(forKey: i == 0 ? kCookieKey : kCookie2Key) ?? ""
        if webWCs[i] == nil || webStamps[i] != raw {
            webWCs[i]?.close()
            webWCs[i] = ClaudeWebWindowController(cookies: museCookies(from: raw), stamp: raw, slot: i)
            webStamps[i] = raw
        }
        guard let wc = webWCs[i] else { return }
        wc.window?.title = "\(claudeName(i)) · Muse 网页"
        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        logLine("Muse open webview slot \(i + 1)")
    }

    private func claudeName(_ i: Int) -> String {
        let s = (UserDefaults.standard.string(forKey: i == 0 ? "qm_claude_name1" : "qm_claude_name2") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "账号 \(i + 1)" : s
    }

    private func claudeCustomName(_ i: Int) -> String? {
        let s = (UserDefaults.standard.string(forKey: i == 0 ? "qm_claude_name1" : "qm_claude_name2") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private var claudePrimary: Int {
        get { UserDefaults.standard.integer(forKey: "qm_claude_primary") == 1 ? 1 : 0 }
        set { UserDefaults.standard.set(newValue, forKey: "qm_claude_primary") }
    }

    private func hasCookie(_ i: Int) -> Bool {
        let key = i == 0 ? kCookieKey : kCookie2Key
        return !(UserDefaults.standard.string(forKey: key) ?? "").isEmpty
    }
    private var todayStat = DayStat()
    private var weekStat = DayStat()
    private var statsUpdated: Date?

    private var lastCodexFetch = Date.distantPast
    private var lastCreditsFetch = Date.distantPast
    private var lastClaudeFetch: [Date] = [.distantPast, .distantPast]
    private var lastStatsFetch = Date.distantPast
    private var codexFetching = false
    private var creditsFetching = false
    private var claudeFetching: [Bool] = [false, false]
    private var statsFetching = false

    private var cookieWC: CookieWindowController?

    // Notification + prediction state
    private var prevUsed: [String: Double] = [:]
    private var lowNotified: [String: Bool] = [:]
    private var creditNotified = Set<String>()
    private var sessionSamples: [(Date, Double)] = []

    // Codex panel
    private let cxSessionRow = BarRow()
    private let cxBurn = NSTextField(labelWithString: "")
    private let cxWeekBurn = NSTextField(labelWithString: "")
    private let cxWeeklyRow = BarRow()
    private let cxCredits = NSTextField(labelWithString: "")
    private let cxStatHead = NSTextField(labelWithString: "用量统计（估算）")
    private let cxToday = NSTextField(labelWithString: "")
    private let cxWeek = NSTextField(labelWithString: "")
    private let cxUpdated = TipTextField.makeLabel("")
    private let cxShortcutPop = NSPopUpButton()
    // Ping (卡五小时窗口)
    private let pingHead = NSTextField(labelWithString: "卡五小时窗口")
    private let pingToggle = NSButton()
    private let pingBox = NSStackView()
    private var codexPanelStack: NSStackView?
    private var claudePanelStack: NSStackView?
    private let pingTarget = TipTextField.makeLabel("")
    private let pingStatus = TipTextField.makeLabel("尚未发送")
    private let pingHistory = TipTextField.makeLabel("")
    private let pingAuto = NSSwitch()
    private let pingAutoWeekly = NSSwitch()
    private let digestHead = NSTextField(labelWithString: "每日小结")
    private let digestSwitch = NSSwitch()
    private let digestHourPop = NSPopUpButton()
    private var lastWeeklyBoundary: Date?
    private var pingPickerWC: PingThreadPickerController?
    private var lastSessionBoundary: Date?
    private var pingSending = false
    private var pingCooldownUntil = Date.distantPast
    private var pingTouched = false
    // Muse panel (two accounts)
    private let muRow1 = BarRow()
    private let muExtra1 = TipTextField.makeLabel("")
    private let muRow2 = BarRow()
    private let muExtra2 = TipTextField.makeLabel("")
    private let muUpdated = TipTextField.makeLabel("")
    private let muSwap = NSButton(title: "", target: nil, action: nil)
    private let muOpen1 = NSButton(title: "打开", target: nil, action: nil)
    private let muOpen2 = NSButton(title: "打开", target: nil, action: nil)
    private var muRowSlot = [0, 1]
    private var webWCs: [Int: ClaudeWebWindowController] = [:]
    private var webStamps: [Int: String] = [:]
    private let muAutoSwitch = NSSwitch()
    private let claudeHover = HoverTracker()
    private var claudeHovering = false
    private lazy var codexAppIcon = appIconImage(bundleIds: ["com.openai.chatgpt", "com.openai.codex"], fallbackSymbol: "terminal")
    private lazy var claudeAppIcon = appIconImage(bundleIds: ["com.meta.endo"], fallbackSymbol: "sparkles")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            logLine("notification authorization: \(granted)")
        }
        backfillPingTokens()
        NotificationCenter.default.addObserver(forName: Notification.Name("qmTextWrapToggled"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            for pop in [self.codexPopover, self.claudePopover, self.sysPopover] where pop.isShown {
                self.syncPanelSize(pop)
            }
        }
        codexItem = makeItem(image: ringIconImage(remaining: nil, icon: codexAppIcon), action: #selector(toggleCodex))
        claudeItem = makeItem(image: ringIconImage(remaining: nil, icon: claudeAppIcon), action: #selector(toggleClaude))
        if let b = codexItem.button {
            codexHover.onEnter = { [weak self] in self?.codexHovering = true; self?.updateCodexUI() }
            codexHover.onExit = { [weak self] in self?.codexHovering = false; self?.updateCodexUI() }
            let ta = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: codexHover, userInfo: nil)
            b.addTrackingArea(ta)
        }
        if let b = claudeItem.button {
            claudeHover.onEnter = { [weak self] in self?.claudeHovering = true; self?.updateClaudeUI() }
            claudeHover.onExit = { [weak self] in self?.claudeHovering = false; self?.updateClaudeUI() }
            let ta = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: claudeHover, userInfo: nil)
            b.addTrackingArea(ta)
        }
        sysItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = sysItem.button {
            let img = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: nil)
            img?.size = NSSize(width: 17, height: 17)
            b.image = img
            b.action = #selector(toggleSys)
            b.target = self
            b.toolTip = "系统资源占用（内存 / 能耗 Top 5）"
        }
        buildPanels()
        schedulerTick()
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.schedulerTick() }
        t.tolerance = 5
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.prewarmWeb() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Keep a status item exactly as wide as the longest title it can
    /// currently show (both hover states are passed as candidates): no
    /// padding out to a theoretical worst case, and no resizing when the
    /// hovered title swaps.
    private func fitItemLength(_ item: NSStatusItem, candidates: [String]) {
        guard let b = item.button else { return }
        let font = b.font ?? NSFont.systemFont(ofSize: 12)
        var w: CGFloat = 0
        for t in candidates { w = max(w, (t as NSString).size(withAttributes: [.font: font]).width) }
        let target = ceil(22 + 5 + w + 3)
        if abs(item.length - target) > 0.5 { item.length = target }
    }

    private func flexSpacer() -> NSView {
        let sp = NSView()
        sp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return sp
    }

    private func makeItem(image: NSImage, action: Selector) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.image = image
            b.title = "--"
            b.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            b.imagePosition = .imageLeft
            b.action = action
            b.target = self
        }
        return item
    }

    private func panel(title: String, rows: [NSView], buttons: [NSButton], footer: NSTextField? = nil) -> NSViewController {
        let vc = NSViewController()
        let view = NSView()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        var btnViews: [NSView] = []
        if let f = footer {
            btnViews.append(f)
            let sp = NSView()
            sp.setContentHuggingPriority(.defaultLow, for: .horizontal)
            sp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            btnViews.append(sp)
        }
        btnViews.append(contentsOf: buttons)
        let btnRow = NSStackView(views: btnViews)
        btnRow.orientation = .horizontal; btnRow.spacing = 8; btnRow.alignment = .centerY
        btnRow.widthAnchor.constraint(equalToConstant: 252).isActive = true
        for b in buttons { b.font = NSFont.systemFont(ofSize: 11.5) }
        let all: [NSView] = [titleLabel] + rows + [btnRow]
        let stack = NSStackView(views: all)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -11),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -9),
        ])
        vc.view = view
        view.layoutSubtreeIfNeeded()
        vc.preferredContentSize = view.fittingSize
        return vc
    }

    private func sectionHead(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func separator() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 252).isActive = true
        return b
    }

    /// A row that right-aligns a quiet action control.
    private func rightRow(_ v: NSView) -> NSStackView {
        let sp = NSView()
        sp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let s = NSStackView(views: [sp, v])
        s.orientation = .horizontal; s.spacing = 8
        s.widthAnchor.constraint(equalToConstant: 252).isActive = true
        return s
    }

    /// NSPopover only grows on its own; push the fitting size explicitly
    /// so collapsing a section shrinks the panel instead of leaving a
    /// blank area under the content.
    private func syncPanelSize(_ pop: NSPopover) {
        guard let vc = pop.contentViewController else { return }
        let stack = (pop === codexPopover) ? codexPanelStack : (pop === sysPopover ? sysPanelStack : claudePanelStack)
        guard let stack = stack else { return }
        let w: CGFloat = (pop === sysPopover) ? sysPanelWidth : 274
        let size = NSSize(width: w, height: ceil(18 + measuredHeight(stack)))
        if abs(pop.contentSize.height - size.height) > 1 {
            logLine("panelsize set=\(Int(size.width))x\(Int(size.height)) was=\(Int(pop.contentSize.width))x\(Int(pop.contentSize.height))")
        }
        vc.preferredContentSize = size
        pop.contentSize = size
    }

    /// Height of a view with hidden stack children excluded, measured by
    /// walking the stacks — NSView.fittingSize cannot be trusted here: the
    /// probe log showed it reporting the expanded height unchanged across
    /// four section toggles.
    private func measuredHeight(_ v: NSView) -> CGFloat {
        if v.isHidden { return 0 }
        if let s = v as? NSStackView {
            if s.orientation == .horizontal {
                return s.arrangedSubviews.filter { !$0.isHidden }.map { measuredHeight($0) }.max() ?? 0
            }
            var h: CGFloat = 0
            var n = 0
            for sub in s.arrangedSubviews where !sub.isHidden {
                h += measuredHeight(sub)
                n += 1
            }
            if n > 1 { h += s.spacing * CGFloat(n - 1) }
            return h
        }
        if let tf = v as? NSTextField {
            // Measure the text at the width it will really get; a wrapping
            // field's fittingSize at frame width 0 wraps into dozens of
            // lines and explodes the total.
            let w = tf.frame.width > 1 ? tf.frame.width : 252
            if let sz = tf.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: CGFloat.greatestFiniteMagnitude)) {
                return sz.height
            }
            return tf.fittingSize.height
        }
        return v.fittingSize.height
    }

    private func applyPingSection() {
        let open = UserDefaults.standard.bool(forKey: "qm_ping_section_open")
        pingToggle.title = (open ? "▾ " : "▸ ") + "卡五小时窗口"
        pingBox.isHidden = !open
        syncPanelSize(codexPopover)
    }

    @objc private func togglePingSection() {
        let now = !UserDefaults.standard.bool(forKey: "qm_ping_section_open")
        UserDefaults.standard.set(now, forKey: "qm_ping_section_open")
        logLine("ping section toggled open=\(now)")
        applyPingSection()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.syncPanelSize(self.codexPopover)
        }
    }

    private func buildPanels() {
        codexPopover.delegate = self
        claudePopover.delegate = self
        sysPopover.delegate = self
        cxBurn.font = NSFont.systemFont(ofSize: 10.5)
        cxBurn.textColor = .secondaryLabelColor
        cxWeekBurn.font = NSFont.systemFont(ofSize: 10.5)
        cxWeekBurn.textColor = .secondaryLabelColor
        cxCredits.font = NSFont.systemFont(ofSize: 11.5)
        cxStatHead.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        cxStatHead.textColor = .secondaryLabelColor
        for l in [cxToday, cxWeek] { l.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular) }
        cxUpdated.font = NSFont.systemFont(ofSize: 10.5); cxUpdated.textColor = .secondaryLabelColor
        cxUpdated.lineBreakMode = .byTruncatingTail
        cxUpdated.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pingHead.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        pingHead.textColor = .secondaryLabelColor
        pingTarget.font = NSFont.systemFont(ofSize: 11.5)
        pingTarget.lineBreakMode = .byTruncatingTail
        pingTarget.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pingStatus.lineBreakMode = .byTruncatingTail
        pingStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pingStatus.font = NSFont.systemFont(ofSize: 10.5); pingStatus.textColor = .secondaryLabelColor
        pingHistory.font = NSFont.systemFont(ofSize: 10.5); pingHistory.textColor = .secondaryLabelColor
        pingHistory.maximumNumberOfLines = 6
        pingHistory.lineBreakMode = .byWordWrapping
        let pingSelect = NSButton(title: "选择对话…", target: self, action: #selector(openPingPicker))
        pingSelect.bezelStyle = .rounded
        let pingSend = NSButton(title: "立即发送你好", target: self, action: #selector(pingNow))
        pingSend.bezelStyle = .rounded
        let pingTargetRow = NSStackView(views: [pingTarget, flexSpacer(), pingSelect])
        pingTargetRow.orientation = .horizontal; pingTargetRow.spacing = 8; pingTargetRow.alignment = .centerY
        pingTargetRow.widthAnchor.constraint(equalToConstant: 252).isActive = true
        let pingStatusRow = NSStackView(views: [pingStatus, flexSpacer(), pingSend])
        pingStatusRow.orientation = .horizontal; pingStatusRow.spacing = 8; pingStatusRow.alignment = .centerY
        pingStatusRow.widthAnchor.constraint(equalToConstant: 252).isActive = true
        pingAuto.target = self; pingAuto.action = #selector(pingAutoChanged)
        let pingAutoLabel = NSTextField(labelWithString: "自动发送")
        pingAutoLabel.font = NSFont.systemFont(ofSize: 11.5)
        pingAutoWeekly.target = self; pingAutoWeekly.action = #selector(pingAutoWeeklyChanged)
        let pingWeeklyLabel = NSTextField(labelWithString: "周也自动")
        pingWeeklyLabel.font = NSFont.systemFont(ofSize: 11.5)
        let pingAutoRow = NSStackView(views: [pingAuto, pingAutoLabel, pingAutoWeekly, pingWeeklyLabel])
        pingAutoRow.orientation = .horizontal; pingAutoRow.spacing = 6; pingAutoRow.alignment = .centerY
        digestHead.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        digestHead.textColor = .secondaryLabelColor
        digestSwitch.target = self; digestSwitch.action = #selector(digestSwitchChanged)
        for (t, h) in [("8:00", 8), ("9:00", 9), ("20:00", 20), ("21:00", 21), ("22:00", 22), ("23:00", 23)] {
            let item = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            item.tag = h
            digestHourPop.menu?.addItem(item)
        }
        digestHourPop.selectItem(withTag: UserDefaults.standard.object(forKey: "qm_digest_hour") as? Int ?? 22)
        digestHourPop.target = self; digestHourPop.action = #selector(digestHourChanged)
        let digestLabel = NSTextField(labelWithString: "每日小结")
        digestLabel.font = NSFont.systemFont(ofSize: 11.5)
        let digestRow = NSStackView(views: [digestSwitch, digestLabel, digestHourPop])
        digestRow.orientation = .horizontal; digestRow.spacing = 8; digestRow.alignment = .centerY
        pingToggle.bezelStyle = .rounded
        pingToggle.font = NSFont.systemFont(ofSize: 11.5)
        pingToggle.alignment = .left
        pingToggle.widthAnchor.constraint(equalToConstant: 252).isActive = true
        pingToggle.target = self; pingToggle.action = #selector(togglePingSection)
        pingBox.orientation = .vertical; pingBox.alignment = .leading; pingBox.spacing = 6
        pingBox.widthAnchor.constraint(equalToConstant: 252).isActive = true
        for v in [pingTargetRow, pingStatusRow, pingAutoRow, pingHistory] {
            pingBox.addArrangedSubview(v)
        }
        applyPingSection()
        let cxRefresh = NSButton(title: "刷新", target: self, action: #selector(refreshCodexNow))
        cxRefresh.bezelStyle = .rounded
        let cxQuit = NSButton(title: "退出", target: self, action: #selector(quitApp))
        cxQuit.bezelStyle = .rounded
        cxShortcutPop.pullsDown = true
        cxShortcutPop.bezelStyle = .rounded
        cxShortcutPop.font = NSFont.systemFont(ofSize: 12)
        cxShortcutPop.translatesAutoresizingMaskIntoConstraints = false
        cxShortcutPop.widthAnchor.constraint(equalToConstant: 252).isActive = true
        rebuildShortcutMenu()
        codexPopover.contentViewController = panel(
            title: "Codex 额度",
            rows: [cxSessionRow, cxBurn, cxWeeklyRow, cxWeekBurn, cxCredits, separator(), cxToday, cxWeek,
                   separator(), pingToggle, pingBox,
                   separator(), digestRow,
                   separator(), cxShortcutPop],
            buttons: [cxRefresh, cxQuit], footer: cxUpdated)
        codexPanelStack = codexPopover.contentViewController?.view.subviews.first as? NSStackView
        codexPopover.behavior = .transient

        for l in [muExtra1, muExtra2] { l.font = NSFont.systemFont(ofSize: 11.5) }
        muSwap.target = self; muSwap.action = #selector(swapClaudePrimary)
        muSwap.bezelStyle = .rounded
        muSwap.font = NSFont.systemFont(ofSize: 12)
        muOpen1.target = self; muOpen1.action = #selector(openClaudeRow1)
        muOpen1.bezelStyle = .rounded; muOpen1.font = NSFont.systemFont(ofSize: 12)
        muOpen2.target = self; muOpen2.action = #selector(openClaudeRow2)
        muOpen2.bezelStyle = .rounded; muOpen2.font = NSFont.systemFont(ofSize: 12)
        muAutoSwitch.target = self; muAutoSwitch.action = #selector(claudeAutoSwitchChanged)
        let muAutoLabel = NSTextField(labelWithString: "主账号剩余低于 15% 时自动切换")
        muAutoLabel.font = NSFont.systemFont(ofSize: 11.5)
        let muAutoRow = NSStackView(views: [muAutoSwitch, muAutoLabel])
        muAutoRow.orientation = .horizontal; muAutoRow.spacing = 8; muAutoRow.alignment = .centerY
        muExtra1.lineBreakMode = .byTruncatingTail
        muExtra2.lineBreakMode = .byTruncatingTail
        muExtra1.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        muExtra2.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let muOpenRow1 = NSStackView(views: [muExtra1, flexSpacer(), muOpen1])
        muOpenRow1.orientation = .horizontal; muOpenRow1.spacing = 8; muOpenRow1.alignment = .centerY
        muOpenRow1.widthAnchor.constraint(equalToConstant: 252).isActive = true
        let muOpenRow2 = NSStackView(views: [muExtra2, flexSpacer(), muOpen2])
        muOpenRow2.orientation = .horizontal; muOpenRow2.spacing = 8; muOpenRow2.alignment = .centerY
        muOpenRow2.widthAnchor.constraint(equalToConstant: 252).isActive = true
        let muSwapRow = rightRow(muSwap)
        muUpdated.font = NSFont.systemFont(ofSize: 10.5); muUpdated.textColor = .secondaryLabelColor
        muUpdated.lineBreakMode = .byTruncatingTail
        muUpdated.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let muRefresh = NSButton(title: "刷新", target: self, action: #selector(refreshClaudeNow))
        muRefresh.bezelStyle = .rounded
        let muCookie = NSButton(title: "设置…", target: self, action: #selector(openCookieWindow))
        muCookie.bezelStyle = .rounded
        let muQuit = NSButton(title: "退出", target: self, action: #selector(quitApp))
        muQuit.bezelStyle = .rounded
        claudePopover.contentViewController = panel(
            title: "Muse 每周额度",
            rows: [muRow1, muOpenRow1, separator(), muRow2, muOpenRow2, muSwapRow, separator(), muAutoRow],
            buttons: [muRefresh, muCookie, muQuit], footer: muUpdated)
        claudePanelStack = claudePopover.contentViewController?.view.subviews.first as? NSStackView
        claudePopover.behavior = .transient

        sysSelf.font = NSFont.systemFont(ofSize: 10.5); sysSelf.textColor = .secondaryLabelColor
        sysSelf.lineBreakMode = .byTruncatingTail
        sysSelf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for box in [sysMemBox, sysCPUBox, sysEnergyBox] {
            box.orientation = .vertical; box.alignment = .leading; box.spacing = 5
            let bc = box.widthAnchor.constraint(equalToConstant: 252); bc.isActive = true; sysColW.append(bc)
        }
        for cap in [sysCapMem, sysCapCPU, sysCapEnergy] {
            cap.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            cap.textColor = .secondaryLabelColor
            cap.lineBreakMode = .byTruncatingTail
        }
        // Three columns side by side: memory, CPU, energy.
        for strip in [stripMem, stripCPU, stripEnergy] {
            strip.translatesAutoresizingMaskIntoConstraints = false
            let sc = strip.widthAnchor.constraint(equalToConstant: 252); sc.isActive = true; sysColW.append(sc)
            strip.heightAnchor.constraint(equalToConstant: 6).isActive = true
        }
        let memCol = NSStackView(views: [sysCapMem, stripMem, sectionHead("内存 Top 5"), sysMemBox])
        memCol.orientation = .vertical; memCol.alignment = .leading; memCol.spacing = 5
        let cpuCol = NSStackView(views: [sysCapCPU, stripCPU, sectionHead("CPU Top 5"), sysCPUBox])
        cpuCol.orientation = .vertical; cpuCol.alignment = .leading; cpuCol.spacing = 5
        let enCol = NSStackView(views: [sysCapEnergy, stripEnergy, sectionHead("能耗 Top 5"), sysEnergyBox])
        enCol.orientation = .vertical; enCol.alignment = .leading; enCol.spacing = 5
        let cols = NSStackView(views: [memCol, cpuCol, enCol])
        cols.orientation = .horizontal; cols.alignment = .top; cols.spacing = 10
        let cc1 = cols.widthAnchor.constraint(equalToConstant: 776); cc1.isActive = true; sysInnerW.append(cc1)
        // Curves row, one sparkline under each column.
        sparkCPU.color = .systemGreen; sparkCPU.ceiling = 100
        sparkMem.color = .systemBlue
        sparkEnergy.color = .systemOrange
        var sparkCols: [NSView] = []
        for (spark, cap) in [(sparkCPU, "CPU"), (sparkMem, "内存"), (sparkEnergy, "能耗")] {
            spark.translatesAutoresizingMaskIntoConstraints = false
            let kc = spark.widthAnchor.constraint(equalToConstant: 252); kc.isActive = true; sysColW.append(kc)
            spark.heightAnchor.constraint(equalToConstant: 34).isActive = true
            let capLabel = NSTextField(labelWithString: cap)
            capLabel.font = NSFont.systemFont(ofSize: 10)
            capLabel.textColor = .secondaryLabelColor
            let c = NSStackView(views: [capLabel, spark])
            c.orientation = .vertical; c.alignment = .leading; c.spacing = 3
            sparkCols.append(c)
        }
        let sparksRow = NSStackView(views: sparkCols)
        sparksRow.orientation = .horizontal; sparksRow.alignment = .top; sparksRow.spacing = 10
        let cc2 = sparksRow.widthAnchor.constraint(equalToConstant: 776); cc2.isActive = true; sysInnerW.append(cc2)
        let sysSep = NSBox(); sysSep.boxType = .separator
        sysSep.translatesAutoresizingMaskIntoConstraints = false
        let cc3 = sysSep.widthAnchor.constraint(equalToConstant: 776); cc3.isActive = true; sysInnerW.append(cc3)
        let sysRefresh = NSButton(title: "刷新", target: self, action: #selector(sysRefreshNow))
        sysRefresh.bezelStyle = .rounded
        let sysQuit = NSButton(title: "退出", target: self, action: #selector(quitApp))
        sysQuit.bezelStyle = .rounded
        for b in [sysRefresh, sysQuit] { b.font = NSFont.systemFont(ofSize: 11.5) }
        let sysBtnRow = NSStackView(views: [sysSelf, flexSpacer(), sysRefresh, sysQuit])
        sysBtnRow.orientation = .horizontal; sysBtnRow.spacing = 8; sysBtnRow.alignment = .centerY
        let cc4 = sysBtnRow.widthAnchor.constraint(equalToConstant: 776); cc4.isActive = true; sysInnerW.append(cc4)
        let sysTitle = NSTextField(labelWithString: "系统资源")
        sysTitle.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        sysPinBtn.target = self; sysPinBtn.action = #selector(toggleSysPin)
        sysPinBtn.bezelStyle = .inline; sysPinBtn.isBordered = false
        sysPinBtn.imagePosition = .imageOnly
        sysPinBtn.translatesAutoresizingMaskIntoConstraints = false
        sysPinBtn.widthAnchor.constraint(equalToConstant: 22).isActive = true
        sysPinBtn.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let sysHeadRow = NSStackView(views: [sysTitle, flexSpacer(), sysPinBtn])
        sysHeadRow.orientation = .horizontal; sysHeadRow.alignment = .centerY; sysHeadRow.spacing = 8
        let cc5 = sysHeadRow.widthAnchor.constraint(equalToConstant: 776); cc5.isActive = true; sysInnerW.append(cc5)
        let sysStack = NSStackView(views: [sysHeadRow, cols, sysSep, sparksRow, sysBtnRow])
        sysStack.orientation = .vertical; sysStack.alignment = .leading; sysStack.spacing = 7
        sysStack.translatesAutoresizingMaskIntoConstraints = false
        let sysView = NSView()
        sysView.addSubview(sysStack)
        NSLayoutConstraint.activate([
            sysStack.leadingAnchor.constraint(equalTo: sysView.leadingAnchor, constant: 11),
            sysStack.trailingAnchor.constraint(equalTo: sysView.trailingAnchor, constant: -11),
            sysStack.topAnchor.constraint(equalTo: sysView.topAnchor, constant: 9),
            sysStack.bottomAnchor.constraint(equalTo: sysView.bottomAnchor, constant: -9),
        ])
        let grip = ResizeGripView()
        grip.translatesAutoresizingMaskIntoConstraints = false
        sysView.addSubview(grip)
        NSLayoutConstraint.activate([
            grip.trailingAnchor.constraint(equalTo: sysView.trailingAnchor, constant: -1),
            grip.bottomAnchor.constraint(equalTo: sysView.bottomAnchor, constant: -1),
            grip.widthAnchor.constraint(equalToConstant: 20),
            grip.heightAnchor.constraint(equalToConstant: 20),
        ])
        grip.onBegin = { [weak self] in self?.sysDragStartWidth = self?.sysPanelWidth }
        grip.onDrag = { [weak self] dx in
            guard let self = self, let s = self.sysDragStartWidth else { return }
            self.applySysWidthLive(s + dx)
        }
        grip.onEnd = { [weak self] in
            guard let self = self else { return }
            self.sysDragStartWidth = nil
            UserDefaults.standard.set(Double(self.sysPanelWidth), forKey: "qm_sys_width")
            self.syncPanelSize(self.sysPopover)
            logLine("sys width set \(Int(self.sysPanelWidth))")
        }
        grip.onReset = { [weak self] in self?.applySysWidth(798, persist: true) }
        let sysVC = NSViewController()
        sysVC.view = sysView
        sysView.layoutSubtreeIfNeeded()
        sysVC.preferredContentSize = sysView.fittingSize
        sysPopover.contentViewController = sysVC
        sysPanelStack = sysStack
        applySysPin()
        applySysWidth(sysPanelWidth, persist: false)
        logLine("sys chip [\(chipBrand())] designMaxW=\(sysDesignMaxW)")
    }

    // Panels close on ANY click outside them (no need to click the icon again).
    private func armOutsideClickWatch() {
        if outsideClickMonitor != nil { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            for pop in [self.codexPopover, self.claudePopover, self.sysPopover] where pop.isShown {
                if pop === self.sysPopover && self.sysPinned { continue }
                if let w = pop.contentViewController?.view.window, !w.frame.contains(NSEvent.mouseLocation) {
                    pop.performClose(nil)
                }
            }
        }
    }

    private func disarmOutsideClickWatchIfIdle() {
        if codexPopover.isShown || claudePopover.isShown || sysPopover.isShown { return }
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === sysPopover { stopSysSampling() }
        disarmOutsideClickWatchIfIdle()
    }

    private func applySysWidthLive(_ w: CGFloat) {
        sysPanelWidth = min(max(w, 600), 900)
        let inner = sysPanelWidth - 22
        for c in sysInnerW { c.constant = inner }
        for c in sysColW { c.constant = sysColWidth() }
        var sz = sysPopover.contentSize
        sz.width = sysPanelWidth
        sysPopover.contentSize = sz
        sysPopover.contentViewController?.preferredContentSize = sz
    }

    private func applySysWidth(_ w: CGFloat, persist: Bool) {
        applySysWidthLive(w)
        if persist { UserDefaults.standard.set(Double(sysPanelWidth), forKey: "qm_sys_width") }
        if sysPopover.contentViewController != nil { syncPanelSize(sysPopover) }
    }

    private func chipBrand() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// Approximate peak package power per chip from public measurements
    /// (Apple publishes no TDP). 0 = unknown chip; the energy strip then
    /// falls back to scaling by the apps' own sum.
    private func computeDesignMaxW() -> Double {
        let b = chipBrand()
        let table: [(String, Double)] = [
            ("M4 Max", 125), ("M4 Pro", 74), ("M4", 46),
            ("M3 Max", 115), ("M3 Pro", 57), ("M3", 42),
            ("M2 Max", 96), ("M2 Pro", 63), ("M2", 36),
            ("M1 Max", 92), ("M1 Pro", 55), ("M1", 31),
        ]
        for (k, v) in table where b.contains(k) { return v }
        return 0
    }

    private func applySysPin() {
        sysPopover.behavior = sysPinned ? .applicationDefined : .transient
        sysPinBtn.image = NSImage(systemSymbolName: sysPinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        sysPinBtn.contentTintColor = sysPinned ? .controlAccentColor : .secondaryLabelColor
        sysPinBtn.toolTip = sysPinned ? "已钉住，点击取消" : "钉住面板"
    }

    @objc private func toggleSysPin() {
        sysPinned.toggle()
        UserDefaults.standard.set(sysPinned, forKey: "qm_sys_pin")
        applySysPin()
        logLine("sys pin \(sysPinned)")
    }

    // MARK: Notifications

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err = err { logLine("notify failed: \(err.localizedDescription)") }
        }
        logLine("notify: \(title) — \(body)")
    }

    private func checkWindow(key: String, name: String, remaining: Double?) {
        guard let r = remaining else { return }
        let used = 100 - r
        if let prev = prevUsed[key], prev >= 50, used <= 2 {
            notify(id: "reset-\(key)-\(Int(Date().timeIntervalSince1970))",
                   title: "\(name)已重置", body: "额度已恢复到 100%")
        }
        prevUsed[key] = used
        if r < 15, lowNotified[key] != true {
            lowNotified[key] = true
            notify(id: "low-\(key)", title: "\(name)即将用完", body: "仅剩 \(Int(r.rounded()))%")
        } else if r >= 25 {
            lowNotified[key] = false
        }
    }

    private func checkCreditExpiry() {
        guard let credits = codexCredits else { return }
        let avail = credits.filter { $0.status.lowercased() == "available" }
        let now = Date()
        for (label, threshold) in [("3d", 3 * 86400.0), ("1d", 86400.0)] {
            let soon = avail.filter { c in
                guard let e = c.expiresAt else { return false }
                let t = e.timeIntervalSince(now)
                return t > 0 && t <= threshold
            }
            guard !soon.isEmpty, let nearest = soon.compactMap({ $0.expiresAt }).min() else { continue }
            let key = "credit-\(label)-\(Int(nearest.timeIntervalSince1970))"
            if creditNotified.contains(key) { continue }
            creditNotified.insert(key)
            notify(id: key, title: "重置券即将到期",
                   body: "\(soon.count) 张 Codex 重置券将在 \(fmtDay(nearest)) 到期（\(compactCountdown(nearest.timeIntervalSince(now))) 后），别浪费")
        }
    }

    private func burnInfo() -> (String, Bool) {
        guard let u = codexUsage, let rem = u.sessionRemaining else { return ("", false) }
        if let a = newestCodexActivity(), Date().timeIntervalSince(a) > 300 { return ("", false) }
        let now = Date()
        let s = sessionSamples.filter { now.timeIntervalSince($0.0) <= 2 * 3600 }
        guard let first = s.first, let last = s.last else { return ("", false) }
        let spanH = last.0.timeIntervalSince(first.0) / 3600
        let delta = last.1 - first.1
        guard spanH >= 8.0 / 60, delta >= 1 else { return ("", false) }
        let rate = delta / spanH
        guard rate > 0 else { return ("", false) }
        let hoursLeft = rem / rate
        if hoursLeft > 24 { return ("", false) }
        if let reset = u.sessionReset, hoursLeft * 3600 >= reset.timeIntervalSinceNow { return ("", false) }
        let eta = now.addingTimeInterval(hoursLeft * 3600)
        return ("按当前速度约 \(fmtReset(eta)) 用完", hoursLeft < 1)
    }

    private func rebuildShortcutMenu() {
        let menu = NSMenu()
        let head = NSMenuItem(title: "快捷对话", action: nil, keyEquivalent: "")
        menu.addItem(head)
        menu.addItem(.separator())
        let links = ShortcutsController.storedLinks
        if links.isEmpty {
            let it = NSMenuItem(title: "（还没有添加）", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        } else {
            for (i, link) in links.enumerated() {
                let it = NSMenuItem(title: link.name.isEmpty ? link.url : link.name,
                                    action: #selector(openShortcut(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
                menu.addItem(it)
            }
        }
        menu.addItem(.separator())
        let mg = NSMenuItem(title: "管理快捷对话…", action: #selector(openShortcutEditor), keyEquivalent: "")
        mg.target = self
        menu.addItem(mg)
        cxShortcutPop.menu = menu
    }

    @objc private func openShortcut(_ sender: NSMenuItem) {
        let links = ShortcutsController.storedLinks
        guard links.indices.contains(sender.tag) else { return }
        codexPopover.performClose(nil)
        ShortcutsController.openLink(links[sender.tag])
    }

    @objc private func openShortcutEditor() {
        codexPopover.performClose(nil)
        ShortcutsController.openEditor()
    }

    @objc private func toggleCodex() {
        if codexPopover.isShown { codexPopover.performClose(nil); return }
        claudePopover.performClose(nil)
        sysPopover.performClose(nil)
        updateCodexUI()
        rebuildShortcutMenu()
        if let b = codexItem.button {
            codexPopover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self else { return }
                self.syncPanelSize(self.codexPopover)
            }
            armOutsideClickWatch()
        }
        if Date().timeIntervalSince(lastStatsFetch) > 60 { computeStats() }
        if Date().timeIntervalSince(lastCodexFetch) > 300 { fetchCodex() }
        if Date().timeIntervalSince(lastCreditsFetch) > 300 { fetchCredits() }
    }

    @objc private func toggleClaude() {
        if claudePopover.isShown { claudePopover.performClose(nil); return }
        codexPopover.performClose(nil)
        sysPopover.performClose(nil)
        updateClaudeUI()
        if let b = claudeItem.button {
            claudePopover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self else { return }
                self.syncPanelSize(self.claudePopover)
            }
            armOutsideClickWatch()
        }
        if Date().timeIntervalSince(lastClaudeFetch[0]) > 300 || Date().timeIntervalSince(lastClaudeFetch[1]) > 300 { fetchClaude() }
    }

    // MARK: System monitor (memory / energy Top 5, sampled only while open)

    @objc private func toggleSys() {
        if sysPopover.isShown { sysPopover.performClose(nil); return }
        codexPopover.performClose(nil)
        claudePopover.performClose(nil)
        if let b = sysItem.button {
            sysPopover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self else { return }
                self.syncPanelSize(self.sysPopover)
            }
            armOutsideClickWatch()
        }
        startSysSampling()
    }

    @objc private func sysRefreshNow() { takeSysSample() }

    private func startSysSampling() {
        stopSysSampling()
        takeSysSample()
        let t = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.takeSysSample() }
        t.tolerance = 0.5
        sysTimer = t
        logLine("sys sampling start")
    }

    private func stopSysSampling() {
        if sysTimer != nil { logLine("sys sampling stop") }
        sysTimer?.invalidate()
        sysTimer = nil
        // Baselines intentionally kept: the first sample after reopening
        // averages over the closed interval and renders instantly,
        // instead of two columns of placeholder text for four seconds.
    }

    private struct SysGroupAgg { var name: String; var path: String; var foot: UInt64 = 0; var energy: UInt64 = 0; var cpu: UInt64 = 0 }

    /// proc_pid_rusage's third argument is the address of the caller's
    /// struct itself (the canonical C usage casts &struct to
    /// rusage_info_t). Passing the address of a pointer slot instead
    /// made the kernel write the whole struct over a stack slot:
    /// SIGABRT, stack buffer overflow, crash report 2026-11-07 18:53:47.
    private func readRusage<T>(_ pid: pid_t, _ flavor: Int32, into info: inout T) -> Bool {
        withUnsafeMutablePointer(to: &info) { p in
            let typed = UnsafeMutableRawPointer(p).assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(pid, flavor, typed) == 0
        }
    }

    /// One rusage pass over every readable pid: phys_footprint for the
    /// memory list (the same number Activity Monitor shows), cumulative
    /// kernel energy counters for the energy list (differenced between
    /// passes into average watts). Processes that refuse rusage (other
    /// users') are skipped; helpers fold into their outermost .app.
    private func takeSysSample() {
        let now = Date()
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return }
        var groups: [String: SysGroupAgg] = [:]
        var skipped = 0
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for pid in pids.prefix(Int(count)) {
            if pid <= 0 { continue }
            var foot: UInt64 = 0
            var energy: UInt64 = 0
            var cpu: UInt64 = 0
            var ok = false
            var ru6 = rusage_info_v6()
            let rc6: Int32 = readRusage(pid, RUSAGE_INFO_V6, into: &ru6) ? 0 : -1
            if rc6 == 0 {
                foot = ru6.ri_phys_footprint
                energy = ru6.ri_energy_nj
                cpu = ru6.ri_user_time + ru6.ri_system_time
                ok = true
            } else {
                var ru4 = rusage_info_v4()
                let rc4: Int32 = readRusage(pid, RUSAGE_INFO_V4, into: &ru4) ? 0 : -1
                if rc4 == 0 {
                    foot = ru4.ri_phys_footprint
                    energy = ru4.ri_billed_energy
                    cpu = ru4.ri_user_time + ru4.ri_system_time
                    ok = true
                }
            }
            if !ok { skipped += 1; continue }
            if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) <= 0 { continue }
            let path = String(cString: pathBuf)
            let key: String
            let name: String
            if let r = path.range(of: ".app/") {
                key = String(path[path.startIndex..<r.upperBound].dropLast())
                name = (key as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            } else {
                key = path
                name = (path as NSString).lastPathComponent
            }
            var g = groups[key] ?? SysGroupAgg(name: name, path: key)
            g.foot += foot
            g.energy += energy
            g.cpu += cpu
            groups[key] = g
        }
        for app in NSWorkspace.shared.runningApplications {
            if let u = app.bundleURL?.path, var g = groups[u], let ln = app.localizedName {
                g.name = ln
                groups[u] = g
            }
        }
        renderSys(groups: groups, now: now, pidCount: Int(count), skipped: skipped)
    }

    private func renderSys(groups: [String: SysGroupAgg], now: Date, pidCount: Int, skipped: Int) {
        let mem = Array(groups.values.sorted { $0.foot > $1.foot }.prefix(5))
        let memTotal = max(groups.values.reduce(0) { $0 + $1.foot }, 1)
        let ramBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let memTopShare = ramBytes > 0 ? Double(mem.reduce(0) { $0 + $1.foot }) / ramBytes : 0
        stripMem.segments = [(memTopShare, NSColor.systemBlue),
                             (max(sysMemUsedFrac01 - memTopShare, 0), NSColor.systemBlue.withAlphaComponent(0.3))]
        fillSysBox(sysMemBox, rows: mem.map { g in
            (icon: sysIcon(g.path), name: g.name, value: fmtBytes(g.foot),
             frac: Double(g.foot) / Double(memTotal), color: NSColor.systemBlue)
        })
        var watts: [(SysGroupAgg, Double)] = []
        for (key, g) in groups {
            guard let prev = sysPrevGroups[key] else { continue }
            let dt = now.timeIntervalSince(prev.time)
            if dt > 0.5, g.energy >= prev.energy {
                let w = Double(g.energy - prev.energy) / 1e9 / dt
                if w > 0.002 { watts.append((g, w)) }
            }
        }
        watts.sort { $0.1 > $1.1 }
        let top = Array(watts.prefix(5))
        if top.isEmpty {
            stripEnergy.segments = []
            sysCapEnergy.stringValue = ""
            fillSysBox(sysEnergyBox, rows: [], placeholder: "")
        } else {
            let totW = max(watts.reduce(0) { $0 + $1.1 }, 0.0001)
            sysCapEnergy.stringValue = String(format: "应用合计 %.1f W", totW)
            let enAlphas: [Double] = [0.95, 0.75, 0.58, 0.43, 0.3]
            if sysDesignMaxW > 0 {
                // Strip scales to the chip's design peak; the row bars
                // below keep scaling to the apps' own sum.
                var segs: [(frac: Double, color: NSColor)] = top.enumerated().map { (i, e) in
                    (e.1 / sysDesignMaxW, NSColor.systemOrange.withAlphaComponent(enAlphas[min(i, 4)]))
                }
                let rest = totW - top.reduce(0) { $0 + $1.1 }
                if rest > 0 { segs.append((rest / sysDesignMaxW, NSColor.systemOrange.withAlphaComponent(0.15))) }
                stripEnergy.segments = segs
            } else {
                stripEnergy.segments = top.enumerated().map { (i, e) in (e.1 / totW, NSColor.systemOrange.withAlphaComponent(enAlphas[min(i, 4)])) }
            }
            fillSysBox(sysEnergyBox, rows: top.map { (g, w) in
                (icon: sysIcon(g.path), name: g.name, value: fmtWatts(w), frac: w / totW, color: NSColor.systemOrange)
            })
        }
        var cpus: [(SysGroupAgg, Double)] = []
        for (key, g) in groups {
            guard let prev = sysPrevGroups[key] else { continue }
            let dt = now.timeIntervalSince(prev.time)
            if dt > 0.5, g.cpu >= prev.cpu {
                let pct = Double(g.cpu - prev.cpu) * machFactor / (dt * 1e9) * 100
                if pct > 0.5 { cpus.append((g, pct)) }
            }
        }
        cpus.sort { $0.1 > $1.1 }
        let topCPU = Array(cpus.prefix(5))
        if topCPU.isEmpty {
            stripCPU.segments = []
            fillSysBox(sysCPUBox, rows: [], placeholder: "")
        } else {
            let cap = Double(ProcessInfo.processInfo.activeProcessorCount) * 100
            let cpuTopShare = topCPU.reduce(0) { $0 + $1.1 } / cap
            stripCPU.segments = [(cpuTopShare, NSColor.systemGreen),
                                 (max(sysTotCPUFrac01 - cpuTopShare, 0), NSColor.systemGreen.withAlphaComponent(0.3))]
            fillSysBox(sysCPUBox, rows: topCPU.map { (g, p) in
                (icon: sysIcon(g.path), name: g.name, value: fmtPct(p), frac: min(p / cap, 1), color: NSColor.systemGreen)
            })
        }
        if !sysPrevGroups.isEmpty {
            appendHist(&histEnergy, now, watts.reduce(0) { $0 + $1.1 })
        }
        sysPrevGroups = groups.mapValues { (energy: $0.energy, cpu: $0.cpu, time: now) }
        var ru = rusage()
        if getrusage(RUSAGE_SELF, &ru) == 0 {
            let cpu = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
                    + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
            var pct = ""
            if let p = sysSelfPrev {
                let dt = now.timeIntervalSince(p.time)
                if dt > 0.2 { pct = String(format: " · CPU %.1f%%", (cpu - p.cpu) / dt * 100) }
            }
            sysSelfPrev = (cpu: cpu, time: now)
            var footText = ""
            var ru6 = rusage_info_v6()
            let rc: Int32 = readRusage(getpid(), RUSAGE_INFO_V6, into: &ru6) ? 0 : -1
            if rc == 0 { footText = "内存 \(fmtBytes(ru6.ri_phys_footprint))" }
            sysSelf.stringValue = "额度环自身：\(footText)\(pct)"
        }
        recordTotals(now: now)
        if sysPopover.isShown { syncPanelSize(sysPopover) }
    }

    private typealias SysRowData = (icon: NSImage?, name: String, value: String, frac: Double, color: NSColor)

    private func fillSysBox(_ box: NSStackView, rows: [SysRowData], placeholder: String? = nil) {
        for v in box.arrangedSubviews { box.removeArrangedSubview(v); v.removeFromSuperview() }
        if rows.isEmpty {
            if let p = placeholder, p.isEmpty { return }
            let l = NSTextField(labelWithString: placeholder ?? "—")
            l.font = NSFont.systemFont(ofSize: 11.5); l.textColor = .secondaryLabelColor
            box.addArrangedSubview(l)
            return
        }
        for r in rows {
            let row = sysRow(r)
            box.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        }
    }

    private func sysRow(_ r: SysRowData) -> NSView {
        let iv = NSImageView()
        iv.image = r.icon
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let name = TipTextField.makeLabel(r.name)
        name.font = NSFont.systemFont(ofSize: 11.5)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let val = NSTextField(labelWithString: r.value)
        val.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        val.alignment = .right
        let head = NSStackView(views: [iv, name, flexSpacer(), val])
        head.orientation = .horizontal; head.spacing = 6; head.alignment = .centerY
        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.3).cgColor
        track.layer?.cornerRadius = 1.5
        track.translatesAutoresizingMaskIntoConstraints = false
        track.heightAnchor.constraint(equalToConstant: 3).isActive = true
        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = r.color.withAlphaComponent(0.85).cgColor
        fill.layer?.cornerRadius = 1.5
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(0.02, min(1, r.frac))),
        ])
        let col = NSStackView(views: [head, track])
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 3
        head.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        track.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    private func sysIcon(_ path: String) -> NSImage? {
        if let img = sysIconCache[path] { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 16, height: 16)
        sysIconCache[path] = img
        return img
    }

    /// Whole-machine totals from two host calls: CPU load from
    /// host_processor_info tick deltas, memory from host_statistics64.
    private func computeTotals() -> (cpuPct: Double?, memUsedGB: Double, memTotalGB: Double, memFreeGB: Double, pressure: Int32) {
        var cpuPct: Double? = nil
        var numCPUs: mach_msg_type_number_t = 0
        var cpuInfo: processor_info_array_t? = nil
        var cpuInfoCount: mach_msg_type_number_t = 0
        let rc = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &cpuInfoCount)
        if rc == KERN_SUCCESS, let info = cpuInfo {
            var u: UInt64 = 0, s: UInt64 = 0, i: UInt64 = 0, n: UInt64 = 0
            let stride = Int(CPU_STATE_MAX)
            for c in 0..<Int(numCPUs) {
                let base = c * stride
                u += UInt64(info[base + Int(CPU_STATE_USER)])
                s += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
                i += UInt64(info[base + Int(CPU_STATE_IDLE)])
                n += UInt64(info[base + Int(CPU_STATE_NICE)])
            }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.size))
            if let p = prevCPUTicks {
                let du = u &- p.user, ds = s &- p.sys, di = i &- p.idle, dn = n &- p.nice
                let total = du + ds + di + dn
                if total > 0 { cpuPct = Double(du + ds + dn) / Double(total) * 100 }
            }
            prevCPUTicks = (user: u, sys: s, idle: i, nice: n)
        }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let mrc = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var totalBytes: UInt64 = 0
        var totalLen = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalBytes, &totalLen, nil, 0)
        var pressure: Int32 = 1
        var plen = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &plen, nil, 0)
        let page = Double(getpagesize())
        let gb = 1_073_741_824.0
        let used = mrc == KERN_SUCCESS ? Double(stats.active_count + stats.wire_count) * page / gb : 0
        let free = mrc == KERN_SUCCESS ? Double(stats.free_count) * page / gb : 0
        return (cpuPct, used, Double(totalBytes) / gb, free, pressure)
    }

    /// Refresh the totals line and the CPU/memory curves. Runs on the
    /// scheduler's existing 30 s tick as well as on panel samples, so
    /// the curves cost no extra wakeups; only totals are recorded in
    /// the background, per-app data stays panel-only.
    private func recordTotals(now: Date) {
        let t = computeTotals()
        if let c = t.cpuPct { appendHist(&histCPU, now, c) }
        sysTotCPUFrac01 = (t.cpuPct ?? 0) / 100
        sysMemUsedFrac01 = t.memTotalGB > 0 ? t.memUsedGB / t.memTotalGB : 0
        appendHist(&histMem, now, t.memUsedGB)
        sparkMem.ceiling = t.memTotalGB > 0 ? t.memTotalGB : nil
        sysCapCPU.stringValue = t.cpuPct.map { String(format: "整机 %.0f%%", $0) } ?? ""
        var memCap = String(format: "已用 %.1f / %.0f GB · 空闲 %.1f GB", t.memUsedGB, t.memTotalGB, t.memFreeGB)
        if t.pressure >= 2 { memCap += " · 压力偏高" }
        sysCapMem.stringValue = memCap
        sparkCPU.values = histCPU.map { $0.1 }
        sparkMem.values = histMem.map { $0.1 }
        sparkEnergy.values = histEnergy.map { $0.1 }
    }

    private func appendHist(_ h: inout [(Date, Double)], _ t: Date, _ v: Double) {
        h.append((t, v))
        let cutoff = t.addingTimeInterval(-3600)
        while let f = h.first, f.0 < cutoff { h.removeFirst() }
        if h.count > 720 { h.removeFirst(h.count - 720) }
    }

    private func fmtPct(_ p: Double) -> String {
        if p >= 10 { return String(format: "%.0f%%", p) }
        return String(format: "%.1f%%", p)
    }

    private func fmtBytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(b) / 1_048_576
        if mb >= 10 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    private func fmtWatts(_ w: Double) -> String {
        if w >= 10 { return String(format: "%.1f W", w) }
        if w >= 1 { return String(format: "%.2f W", w) }
        return String(format: "%.0f mW", w * 1000)
    }

    @objc private func refreshCodexNow() { fetchCodex(); fetchCredits(); computeStats() }
    @objc private func refreshClaudeNow() { fetchClaude() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func openCookieWindow() {
        claudePopover.performClose(nil)
        let wc = CookieWindowController()
        wc.onSave = { [weak self] c1, c2, n1, n2 in
            if !c1.isEmpty { UserDefaults.standard.set(c1, forKey: kCookieKey) }
            if !c2.isEmpty { UserDefaults.standard.set(c2, forKey: kCookie2Key) }
            UserDefaults.standard.set(n1, forKey: "qm_claude_name1")
            UserDefaults.standard.set(n2, forKey: "qm_claude_name2")
            UserDefaults.standard.removeObject(forKey: kActionKey)
            logLine("cookie updated by user")
            self?.lastClaudeFetch = [.distantPast, .distantPast]
            self?.fetchClaude()
        }
        cookieWC = wc
        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    /// Idle self-usage for the gauge item's hover tooltip: what the app
    /// costs while it is NOT sampling. Runs on the existing 30 s tick and
    /// only while the panel is closed, so the number stays a true idle
    /// baseline to compare against the in-panel sampling figure.
    private func updateSelfIdle(now: Date) {
        if sysTimer != nil { return }
        var ru6 = rusage_info_v6()
        guard readRusage(getpid(), RUSAGE_INFO_V6, into: &ru6) else { return }
        let cpuSec = Double(ru6.ri_user_time + ru6.ri_system_time) * machFactor / 1e9
        var cpuText = ""
        if let p = selfIdlePrev {
            let dt = now.timeIntervalSince(p.time)
            if dt > 1 { cpuText = String(format: " · CPU %.1f%%", (cpuSec - p.cpuSec) / dt * 100) }
        }
        selfIdlePrev = (cpuSec, now)
        sysItem.button?.toolTip = "额度环静息：内存 \(fmtBytes(ru6.ri_phys_footprint))\(cpuText)"
    }

    private func schedulerTick() {
        let now = Date()
        recordTotals(now: now)
        updateSelfIdle(now: now)
        let museDue = (0...1).contains { hasCookie($0) && now.timeIntervalSince(lastClaudeFetch[$0]) >= 1800 }
        if museDue { fetchClaude() }
        let active = newestCodexActivity().map { now.timeIntervalSince($0) < 180 } ?? false
        let codexInterval: TimeInterval = active ? 60 : 1800
        if now.timeIntervalSince(lastCodexFetch) >= codexInterval { fetchCodex() }
        if now.timeIntervalSince(lastCreditsFetch) >= (active ? 300 : 1800) { fetchCredits() }
        if now.timeIntervalSince(lastStatsFetch) >= (active ? 120 : 1800) { computeStats() }
        if pingBoundaryPending(now: now), now.timeIntervalSince(lastCodexFetch) > 45 { fetchCodex() }
        checkDigest(now: now)
    }

    private func fetchCodex() {
        if codexFetching { return }
        codexFetching = true
        lastCodexFetch = Date()
        codexClient.fetchUsage { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.codexFetching = false
                switch outcome {
                case .ok(let u):
                    self.codexUsage = u; self.codexStatus = "正常"
                    self.detectRoll(u: u)
                    if let r = u.sessionReset { self.lastSessionBoundary = r }
                    if let r = u.weeklyReset { self.lastWeeklyBoundary = r }
                    if let wu = u.weeklyUsed {
                        var arr = UserDefaults.standard.array(forKey: "qm_weekly_samples") as? [[Double]] ?? []
                        arr.append([Date().timeIntervalSince1970, wu])
                        let cutoff = Date().timeIntervalSince1970 - 3 * 24 * 3600
                        arr = arr.filter { $0[0] >= cutoff }
                        if arr.count > 300 { arr = Array(arr.suffix(300)) }
                        UserDefaults.standard.set(arr, forKey: "qm_weekly_samples")
                    }
                    logLine("codex ok session=\(u.sessionUsed.map { Int($0) } ?? -1) weekly=\(u.weeklyUsed.map { Int($0) } ?? -1)")
                    if let su = u.sessionUsed {
                        self.sessionSamples.append((Date(), su))
                        self.sessionSamples = self.sessionSamples.filter { Date().timeIntervalSince($0.0) <= 2 * 3600 }
                    }
                    self.checkWindow(key: "codex-session", name: "Codex 5 小时额度", remaining: u.sessionRemaining)
                    self.checkWindow(key: "codex-weekly", name: "Codex 每周额度", remaining: u.weeklyRemaining)
                case .noAuth:
                    self.codexUsage = nil; self.codexStatus = "未找到 Codex 登录文件（~/.codex/auth.json）"
                    logLine("codex: no auth file")
                case .expired:
                    self.codexStatus = "登录已过期，用一次 Codex 后自动恢复"
                    logLine("codex: token expired")
                case .failed(let m):
                    self.codexStatus = "出错：\(m)"
                    logLine("codex failed: \(m)")
                }
                self.updateCodexUI()
            }
        }
    }

    private func fetchCredits() {
        if creditsFetching { return }
        creditsFetching = true
        lastCreditsFetch = Date()
        codexClient.fetchResetCredits { [weak self] credits in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.creditsFetching = false
                if let credits = credits {
                    self.codexCredits = credits
                    let statuses = credits.map { $0.status }.joined(separator: ",")
                    logLine("credits n=\(credits.count) statuses=[\(statuses)]")
                    self.checkCreditExpiry()
                }
                self.updateCodexUI()
            }
        }
    }

    private func fetchClaude() {
        for i in 0...1 where hasCookie(i) { fetchClaudeAccount(i) }
        if !hasCookie(0) && !hasCookie(1) {
            claudeStatuses[0] = "未设置 Cookie：点我后选「设置 Cookie…」"
            updateClaudeUI()
        }
    }

    private func fetchClaudeAccount(_ i: Int) {
        if claudeFetching[i] { return }
        claudeFetching[i] = true
        lastClaudeFetch[i] = Date()
        let label = claudeName(i)
        claudeClients[i].fetchUsage { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.claudeFetching[i] = false
                switch outcome {
                case .ok(let u):
                    self.claudeUsages[i] = u; self.claudeStatuses[i] = "正常"
                    logLine("Muse[\(i + 1)] ok used=\(Int(u.percentUsed))%")
                    self.checkWindow(key: "claude-weekly-\(i + 1)", name: "Muse \(label) 每周额度", remaining: u.remaining)
                case .noCookie:
                    self.claudeStatuses[i] = "未设置 Cookie"
                case .signedOut:
                    self.claudeUsages[i] = nil; self.claudeStatuses[i] = "登录已过期：重新粘贴 Cookie"
                    logLine("Muse[\(i + 1)]: signed out")
                case .failed(let m):
                    self.claudeStatuses[i] = "出错：\(m)"
                    logLine("Muse[\(i + 1)] failed: \(m)")
                }
                self.updateClaudeUI()
            }
        }
    }


    // MARK: Ping （卡五小时窗口）

    @objc private func openPingPicker() {
        codexPopover.performClose(nil)
        let wc = PingThreadPickerController(entries: threadEntries())
        wc.onPick = { [weak self] id, name in
            UserDefaults.standard.set(id, forKey: "qm_ping_thread")
            UserDefaults.standard.set(name, forKey: "qm_ping_thread_name")
            logLine("ping target set: \(name)")
            self?.updateCodexUI()
        }
        wc.onCreate = { [weak self] in self?.createPingThread() }
        pingPickerWC = wc
        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func pingNow() { runPing(auto: false) }

    @objc private func pingAutoChanged() {
        let on = pingAuto.state == .on
        UserDefaults.standard.set(on, forKey: "qm_ping_auto")
        logLine("ping auto: \(on)")
    }

    private func threadEntries() -> [(id: String, name: String, updated: Date)] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var best: [String: (String, Date)] = [:]
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String,
                  let name = obj["thread_name"] as? String, !name.isEmpty,
                  name != "Guardian review" else { continue }
            let d = (obj["updated_at"] as? String).flatMap { f1.date(from: $0) ?? f2.date(from: $0) } ?? .distantPast
            if let cur = best[id], cur.1 >= d { continue }
            best[id] = (name, d)
        }
        return Array(best.map { (id: $0.key, name: $0.value.0, updated: $0.value.1) }
            .sorted { $0.updated > $1.updated }
            .prefix(20))
    }

    private func resolveCodexBinary() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                          "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                          "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                          "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          home + "/.local/bin/codex", home + "/.npm-global/bin/codex",
                          home + "/.bun/bin/codex"]
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v codex"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    private func sessionCwd(id: String) -> String? {
        let fm = FileManager.default
        let roots = [fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
                     fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/archived_sessions")]
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let f as URL in en {
                guard f.lastPathComponent.hasSuffix("\(id).jsonl") else { continue }
                guard let data = try? Data(contentsOf: f),
                      let nl = data.firstIndex(of: 0x0A) else { return nil }
                let first = data.subdata(in: 0..<nl)
                if let obj = try? JSONSerialization.jsonObject(with: first) as? [String: Any],
                   let payload = obj["payload"] as? [String: Any],
                   let cwd = payload["cwd"] as? String { return cwd }
                return nil
            }
        }
        return nil
    }

    private func execPingOnce(bin: String, args: [String], cwd: String?) -> (code: Int32, out: String, tail: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        if let cwd = cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        let sema = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sema.signal() }
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        if sema.wait(timeout: .now() + 180) == .timedOut {
            p.terminate()
            _ = sema.wait(timeout: .now() + 5)
            return (-2, "", "timeout 180s")
        }
        let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let outText = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let tail = String(errText.suffix(300)).replacingOccurrences(of: "\n", with: " ")
        return (p.terminationStatus, outText, tail)
    }

    private func cheapestCodexModel() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let models: [[String: Any]]
        if let d = obj as? [String: Any] { models = (d["models"] as? [[String: Any]]) ?? [] }
        else { models = (obj as? [[String: Any]]) ?? [] }
        let markers = ["affordable", "cheap", "low cost", "low-cost", "mini", "luna"]
        var bestSlug: String?
        var bestPriority = Int.min
        for m in models {
            guard let slug = m["slug"] as? String, !slug.isEmpty else { continue }
            if let vis = m["visibility"] as? String, vis != "list" { continue }
            let hay = ((m["description"] as? String ?? "") + " " + slug).lowercased()
            guard markers.contains(where: { hay.contains($0) }) else { continue }
            let prio = (m["priority"] as? NSNumber)?.intValue ?? 0
            if prio > bestPriority || (prio == bestPriority && slug < (bestSlug ?? "\u{10FFFF}")) {
                bestPriority = prio; bestSlug = slug
            }
        }
        return bestSlug
    }

    /// One raw Responses turn against the ChatGPT backend — the same endpoint
    /// the Codex CLI uses, billed to the subscription, but without the agent
    /// system prompt (which is what makes the CLI path cost ~12k+ tokens).
    /// Shape mirrors windowping's measured api mode (~16 tokens per ping).
    private func pingViaAPI() -> (ok: Bool, tokens: Int?, error: String?) {
        guard let auth = codexClient.pingAuth() else { return (false, nil, "读不到登录令牌") }
        guard let model = cheapestCodexModel() else { return (false, nil, "读不到模型目录") }
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "input": [["role": "user", "content": [["type": "input_text", "text": "你好"]]]],
            "tools": [],
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "reasoning": ["effort": "low"],
            "store": false,
            "include": [],
            "max_output_tokens": 16,
        ]
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        if let aid = auth.accountId { req.setValue(aid, forHTTPHeaderField: "ChatGPT-Account-ID") }
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.setValue("codex_cli_rs/0.167.0", forHTTPHeaderField: "User-Agent")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "session-id")
        req.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "thread-id")
        req.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "x-client-request-id")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var resultData: Data?
        var resultStatus = 0
        var resultErr: Error?
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, e in
            resultData = d
            resultStatus = (r as? HTTPURLResponse)?.statusCode ?? 0
            resultErr = e
            sema.signal()
        }.resume()
        if sema.wait(timeout: .now() + 70) == .timedOut { return (false, nil, "接口超时") }
        if let e = resultErr { return (false, nil, "网络错误 \(e.localizedDescription)") }
        guard resultStatus == 200, let data = resultData else {
            let snippet = resultData.map { String(decoding: $0.prefix(300), as: UTF8.self) } ?? ""
            return (false, nil, "HTTP \(resultStatus): \(snippet)")
        }
        let text = String(decoding: data, as: UTF8.self)
        var completed = false
        var failure: String?
        var inTok: Int?
        var outTok: Int?
        for line in text.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("data:") else { continue }
            let payload = s.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let d = String(payload).data(using: .utf8),
                  let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let kind = ev["type"] as? String else { continue }
            if kind == "response.completed" {
                completed = true
                var usage = ev["usage"] as? [String: Any]
                if usage == nil, let resp = ev["response"] as? [String: Any] {
                    usage = resp["usage"] as? [String: Any]
                }
                if let u = usage {
                    inTok = (u["input_tokens"] as? NSNumber)?.intValue
                    outTok = (u["output_tokens"] as? NSNumber)?.intValue
                }
            } else if kind == "error" || kind == "response.failed" {
                if let eobj = ev["error"] as? [String: Any] { failure = (eobj["message"] as? String) ?? "请求失败" }
                else if let es = ev["error"] as? String { failure = es }
                else { failure = "请求失败" }
            }
        }
        if let f = failure, !completed { return (false, nil, f) }
        guard completed else { return (false, nil, "数据流未完成") }
        let total = (inTok != nil || outTok != nil) ? (inTok ?? 0) + (outTok ?? 0) : nil
        logLine("ping api ok model=\(model) tokens=\(total ?? -1)")
        return (true, total, nil)
    }

    private func runPing(auto: Bool, boundary: Date? = nil, weeklyBoundary: Date? = nil) {
        guard !pingSending else { return }
        pingTouched = true
        pingSending = true
        pingStatus.stringValue = "发送中…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let api = self.pingViaAPI()
            if api.ok {
                self.finishPing(auto: auto, boundary: boundary, weeklyBoundary: weeklyBoundary, ok: true, route: "接口", tokens: api.tokens, failText: "", logText: "")
                return
            }
            logLine("ping api failed: \(api.error ?? "?") -> cli fallback")
            let id = UserDefaults.standard.string(forKey: "qm_ping_thread") ?? ""
            guard !id.isEmpty, let bin = self.resolveCodexBinary() else {
                self.finishPing(auto: auto, boundary: boundary, weeklyBoundary: weeklyBoundary, ok: false, route: "接口", tokens: nil,
                                failText: "发送失败：接口不通（\(api.error ?? "")），也没有可用的命令行兜底",
                                logText: "api failed and no cli fallback: \(api.error ?? "")")
                return
            }
            let cwd = self.sessionCwd(id: id)
            var res = self.execPingOnce(bin: bin, args: ["exec", "resume", "--all", "--skip-git-repo-check", id, "你好"], cwd: cwd)
            var via = "A"
            if res.code != 0 {
                res = self.execPingOnce(bin: bin, args: ["exec", "--skip-git-repo-check", "resume", "--all", id, "你好"], cwd: cwd)
                via = "B"
            }
            if res.code == 0 {
                logLine("ping cli ok via \(via)")
                self.finishPing(auto: auto, boundary: boundary, weeklyBoundary: weeklyBoundary, ok: true, route: "命令行", tokens: nil, failText: "", logText: "")
            } else if res.tail.contains("active writer") {
                self.finishPing(auto: auto, boundary: boundary, weeklyBoundary: weeklyBoundary, ok: false, route: "命令行", tokens: nil,
                                failText: "发送失败：这个对话正开在 ChatGPT 里被占用——在应用里切到别的对话，或改用专用对话",
                                logText: "cli code=\(res.code) tail=\(res.tail)")
            } else {
                self.finishPing(auto: auto, boundary: boundary, weeklyBoundary: weeklyBoundary, ok: false, route: "命令行", tokens: nil,
                                failText: "发送失败（退出码 \(res.code)），详情看日志",
                                logText: "cli code=\(res.code) tail=\(res.tail)")
            }
        }
    }

    private func finishPing(auto: Bool, boundary: Date?, weeklyBoundary: Date?, ok: Bool, route: String, tokens: Int?, failText: String, logText: String) {
        DispatchQueue.main.async {
            self.pingSending = false
            let kind = "\(auto ? "自动" : "手动")·\(route)"
            if ok {
                if let b = boundary { UserDefaults.standard.set(b.timeIntervalSince1970, forKey: "qm_ping_last_reset") }
                if let wb = weeklyBoundary { UserDefaults.standard.set(wb.timeIntervalSince1970, forKey: "qm_ping_last_weekly_reset") }
                let df = DateFormatter(); df.dateFormat = "HH:mm"
                var s = "已发送 \(df.string(from: Date())) · \(route)"
                if let t = tokens { s += " · \(t) tokens" }
                self.pingStatus.stringValue = s
                logLine("ping ok (\(auto ? "auto" : "manual"), via \(route)" + (tokens.map { ", \($0) tokens" } ?? ""))
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "qm_ping_last_sent")
                UserDefaults.standard.set(auto, forKey: "qm_ping_last_auto")
                UserDefaults.standard.set(route, forKey: "qm_ping_last_route")
                if let t = tokens { UserDefaults.standard.set(t, forKey: "qm_ping_last_tokens") }
                self.recordPing(kind: kind, ok: true, tokens: tokens)
                if auto {
                    self.notify(id: "ping-ok-\(Int(Date().timeIntervalSince1970))",
                                title: "自动发送你好成功", body: "五小时新窗口已经开启")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.fetchCodex() }
            } else {
                self.pingCooldownUntil = Date().addingTimeInterval(600)
                self.recordPing(kind: kind, ok: false)
                self.pingStatus.stringValue = failText
                logLine("ping failed: \(logText)")
                if auto {
                    self.notify(id: "ping-fail-\(Int(Date().timeIntervalSince1970))",
                                title: "自动发送你好失败", body: "卡窗口没成功，点开 Codex 面板看一眼")
                }
            }
            self.updateCodexUI()
        }
    }

    /// One-time: sends from before v4.7 have no token count stored, but
    /// the app's own log recorded the exact figures at send time
    /// ("ping ok (auto, via 接口, 20 tokens"). Match history entries
    /// against it once and fill the numbers in.
    private func backfillPingTokens() {
        let d = UserDefaults.standard
        if d.bool(forKey: "qm_ping_backfill_v1") { return }
        d.set(true, forKey: "qm_ping_backfill_v1")
        let logPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/quotameter.log")
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }
        var found: [String: Int] = [:]
        let logRe = try! NSRegularExpression(pattern: "\\] ping ok \\((auto|manual), via ([^,]+), (\\d+) tokens")
        let timeRe = try! NSRegularExpression(pattern: "(\\d{2}):(\\d{2}):\\d{2}\\] ping ok")
        for line in text.split(separator: "\n") {
            let s = String(line)
            guard let m = logRe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let tm = timeRe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
            func g(_ re: NSRegularExpression, _ mm: NSTextCheckingResult, _ i: Int) -> String {
                String(s[Range(mm.range(at: i), in: s)!])
            }
            let kind = g(logRe, m, 1) == "auto" ? "自动" : "手动"
            found["\(g(timeRe, tm, 1)):\(g(timeRe, tm, 2))|\(kind)|\(g(logRe, m, 2))"] = Int(g(logRe, m, 3))
        }
        if found.isEmpty { logLine("ping backfill: no log matches"); return }
        let histRe = try! NSRegularExpression(pattern: "(\\d{2}):(\\d{2}) · (自动|手动)·(接口|命令行) · 成功")
        var hist = d.stringArray(forKey: "qm_ping_history") ?? []
        var changed = 0
        for i in hist.indices where !hist[i].contains("tokens") {
            let s = hist[i]
            guard let m = histRe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
            func g(_ j: Int) -> String { String(s[Range(m.range(at: j), in: s)!]) }
            if let t = found["\(g(1)):\(g(2))|\(g(3))|\(g(4))"] {
                hist[i] += " · \(t) tokens"
                changed += 1
            }
        }
        if changed > 0 { d.set(hist, forKey: "qm_ping_history") }
        if d.integer(forKey: "qm_ping_last_tokens") == 0, let first = hist.first,
           let m = histRe.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)) {
            func g(_ j: Int) -> String { String(first[Range(m.range(at: j), in: first)!]) }
            if let t = found["\(g(1)):\(g(2))|\(g(3))|\(g(4))"] {
                d.set(g(4), forKey: "qm_ping_last_route")
                d.set(t, forKey: "qm_ping_last_tokens")
            }
        }
        logLine("ping backfill matched \(changed) entries")
    }

    private func recordPing(kind: String, ok: Bool, tokens: Int? = nil) {
        let df = DateFormatter(); df.dateFormat = "M月d日 HH:mm"
        var entry = "\(df.string(from: Date())) · \(kind) · \(ok ? "成功" : "失败")"
        if let t = tokens { entry += " · \(t) tokens" }
        var arr = UserDefaults.standard.stringArray(forKey: "qm_ping_history") ?? []
        arr.insert(entry, at: 0)
        if arr.count > 5 { arr = Array(arr.prefix(5)) }
        UserDefaults.standard.set(arr, forKey: "qm_ping_history")
        renderPingHistory()
    }

    private func renderPingHistory() {
        let arr = UserDefaults.standard.stringArray(forKey: "qm_ping_history") ?? []
        pingHistory.stringValue = arr.isEmpty ? "" : "发送记录（最近 5 次）\n" + arr.joined(separator: "\n")
        pingHistory.isHidden = arr.isEmpty
    }

    private func createPingThread() {
        guard !pingSending else { return }
        pingTouched = true
        guard let bin = resolveCodexBinary() else {
            pingStatus.stringValue = "找不到 codex 命令"
            logLine("ping create failed: codex binary not found")
            return
        }
        pingSending = true
        pingStatus.stringValue = "正在新建专用对话…"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let res = self.execPingOnce(bin: bin, args: ["exec", "--json", "--skip-git-repo-check", "你好"], cwd: home)
            var newId: String?
            if res.code == 0 {
                for line in res.out.split(separator: "\n") {
                    guard let d = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let tid = obj["thread_id"] as? String else { continue }
                    newId = tid; break
                }
            }
            let code = res.code, tail = res.tail
            DispatchQueue.main.async {
                self.pingSending = false
                if let tid = newId {
                    UserDefaults.standard.set(tid, forKey: "qm_ping_thread")
                    UserDefaults.standard.set("卡窗口专用", forKey: "qm_ping_thread_name")
                    self.pingStatus.stringValue = "专用对话已建好（刚才已顺带发出第一句你好）"
                    logLine("ping thread created: \(tid)")
                    self.recordPing(kind: "新建专用对话", ok: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.fetchCodex() }
                } else {
                    self.pingStatus.stringValue = "新建失败（退出码 \(code)），详情看日志"
                    logLine("ping create failed code=\(code) tail=\(tail)")
                }
                self.updateCodexUI()
            }
        }
    }

    /// True while a known reset moment has passed but has not been processed yet.
    private func pingBoundaryPending(now: Date) -> Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: "qm_ping_auto") {
            let prev = d.double(forKey: "qm_ping_prev_reset")
            if prev > 0, now.timeIntervalSince1970 >= prev,
               d.double(forKey: "qm_ping_last_reset") < prev { return true }
        }
        if d.bool(forKey: "qm_ping_auto_weekly") {
            let prev = d.double(forKey: "qm_ping_prev_weekly_reset")
            if prev > 0, now.timeIntervalSince1970 >= prev,
               d.double(forKey: "qm_ping_last_weekly_reset") < prev { return true }
        }
        return false
    }

    /// Roll detection, run on every successful usage fetch. Compares against the
    /// reset time known BEFORE this window rolled (qm_ping_prev_reset): once that
    /// moment has passed and the fresh window is still <=5% used, it has not been
    /// anchored yet — ping now. The boundary is marked processed either way
    /// (pinged, skipped for low weekly quota, or already started by the user).
    private func detectRoll(u: CodexUsage) {
        let d = UserDefaults.standard
        let now = Date()
        var due5: Date?
        var dueW: Date?
        if d.bool(forKey: "qm_ping_auto") {
            let prev = d.double(forKey: "qm_ping_prev_reset")
            if prev > 0, now.timeIntervalSince1970 >= prev,
               d.double(forKey: "qm_ping_last_reset") < prev {
                if (u.sessionUsed ?? 0) <= 5 {
                    if let w = u.weeklyRemaining, w < 10 {
                        logLine("ping skipped: weekly remaining \(Int(w))%")
                    } else {
                        due5 = Date(timeIntervalSince1970: prev)
                    }
                }
                d.set(prev, forKey: "qm_ping_last_reset")
            }
        }
        if d.bool(forKey: "qm_ping_auto_weekly") {
            let prev = d.double(forKey: "qm_ping_prev_weekly_reset")
            if prev > 0, now.timeIntervalSince1970 >= prev,
               d.double(forKey: "qm_ping_last_weekly_reset") < prev {
                if (u.weeklyUsed ?? 0) <= 5 {
                    dueW = Date(timeIntervalSince1970: prev)
                }
                d.set(prev, forKey: "qm_ping_last_weekly_reset")
            }
        }
        if let r = u.sessionReset { d.set(r.timeIntervalSince1970, forKey: "qm_ping_prev_reset") }
        if let r = u.weeklyReset { d.set(r.timeIntervalSince1970, forKey: "qm_ping_prev_weekly_reset") }
        if (due5 != nil || dueW != nil) && !pingSending {
            runPing(auto: true, boundary: due5, weeklyBoundary: dueW)
        }
    }

    @objc private func swapClaudePrimary() {
        claudePrimary = 1 - claudePrimary
        logLine("Muse primary -> \(claudePrimary + 1)")
        updateClaudeUI()
    }

    @objc private func claudeAutoSwitchChanged() {
        let on = muAutoSwitch.state == .on
        UserDefaults.standard.set(on, forKey: "qm_claude_autoswitch")
        logLine("Muse autoswitch: \(on)")
        if on { updateClaudeUI() }
    }

    /// With auto-switch on: if the primary account is nearly empty and the
    /// other account is clearly healthier, promote the other one.
    private func maybeAutoSwitchClaude() {
        guard UserDefaults.standard.bool(forKey: "qm_claude_autoswitch") else { return }
        let p = claudePrimary, o = 1 - p
        guard hasCookie(o), let pu = claudeUsages[p], let ou = claudeUsages[o] else { return }
        if pu.remaining < 15, ou.remaining > pu.remaining + 10 {
            claudePrimary = o
            logLine("Muse auto switch: primary -> \(o + 1) (was \(Int(pu.remaining.rounded()))%, other \(Int(ou.remaining.rounded()))%)")
            notify(id: "claude-autoswitch-\(Int(Date().timeIntervalSince1970))",
                   title: "Muse 主账号已自动切换",
                   body: "\(claudeName(o)) 成为主账号（原主账号仅剩 \(Int(pu.remaining.rounded()))%）")
        }
    }

    @objc private func pingAutoWeeklyChanged() {
        let on = pingAutoWeekly.state == .on
        UserDefaults.standard.set(on, forKey: "qm_ping_auto_weekly")
        logLine("ping auto weekly: \(on)")
    }

    @objc private func digestSwitchChanged() {
        let on = digestSwitch.state == .on
        UserDefaults.standard.set(on, forKey: "qm_digest_on")
        logLine("digest on: \(on)")
    }

    @objc private func digestHourChanged() {
        let h = digestHourPop.selectedTag()
        UserDefaults.standard.set(h, forKey: "qm_digest_hour")
        logLine("digest hour: \(h)")
    }

    /// Weekly burn-down forecast from persisted weekly-used samples (48h span).
    private func weeklyBurnInfo() -> (String, Bool) {
        guard let u = codexUsage, let rem = u.weeklyRemaining, let reset = u.weeklyReset else { return ("", false) }
        let raw = UserDefaults.standard.array(forKey: "qm_weekly_samples") as? [[Double]] ?? []
        let now = Date()
        let pts = raw.map { (Date(timeIntervalSince1970: $0[0]), $0[1]) }
            .filter { now.timeIntervalSince($0.0) <= 48 * 3600 }
        guard let first = pts.first, let last = pts.last else { return ("", false) }
        let spanH = last.0.timeIntervalSince(first.0) / 3600
        let delta = last.1 - first.1
        guard spanH >= 6, delta >= 2 else { return ("", false) }
        let rate = delta / spanH
        guard rate > 0 else { return ("", false) }
        let eta = now.addingTimeInterval(rem / rate * 3600)
        guard eta < reset else { return ("", false) }
        let df = DateFormatter(); df.dateFormat = "M月d日 HH:mm"
        return ("周额度按近两天速度约 \(df.string(from: eta)) 用完", eta.timeIntervalSince(now) < 24 * 3600)
    }

    private func checkDigest(now: Date) {
        guard UserDefaults.standard.bool(forKey: "qm_digest_on") else { return }
        let hour = UserDefaults.standard.object(forKey: "qm_digest_hour") as? Int ?? 22
        let cal = Calendar.current
        guard let target = cal.date(bySettingHour: hour, minute: 0, second: 0, of: now), now >= target else { return }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: now)
        guard UserDefaults.standard.string(forKey: "qm_digest_day") != today else { return }
        UserDefaults.standard.set(today, forKey: "qm_digest_day")
        fetchCodex(); fetchClaude(); computeStats()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self else { return }
            var parts: [String] = []
            parts.append("Codex 今日 \(fmtTokens(self.todayStat.tokens)) tokens · \(fmtMoney(self.todayStat.cost))")
            if let u = self.codexUsage {
                if let s = u.sessionRemaining { parts.append("5 小时剩 \(Int(s.rounded()))%") }
                if let w = u.weeklyRemaining { parts.append("周剩 \(Int(w.rounded()))%") }
            }
            for i in 0...1 where self.hasCookie(i) {
                if let cu = self.claudeUsages[i] {
                    parts.append("Muse \(claudeName(i)) 剩 \(Int(cu.remaining.rounded()))%")
                }
            }
            self.notify(id: "digest-\(today)", title: "额度环每日小结", body: parts.joined(separator: "；"))
            logLine("digest sent: \(parts.joined(separator: " | "))")
        }
    }

    private func computeStats() {
        if statsFetching { return }
        statsFetching = true
        lastStatsFetch = Date()
        stats.compute { [weak self] today, week in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.statsFetching = false
                self.todayStat = today; self.weekStat = week
                self.statsUpdated = Date()
                logLine("stats today=\(today.tokens) week=\(week.tokens)")
                self.updateCodexUI()
            }
        }
    }

    private func resetSub(_ reset: Date?) -> String {
        guard let r = reset else { return "" }
        return "\(fmtReset(r)) 重置"
    }

    private func creditsText() -> String {
        guard let credits = codexCredits else { return "" }
        let avail = credits.filter { $0.status.lowercased() == "available" }
        let others = credits.count - avail.count
        if avail.isEmpty { return credits.isEmpty ? "" : "重置券：暂无可用" }
        var s = "重置券：\(avail.count) 张可用"
        let exps = avail.compactMap { $0.expiresAt }.sorted()
        if let e = exps.first {
            s += " · 最近 \(fmtDay(e)) 到期"
        }
        if others > 0 { s += " · 另 \(others) 张已用/过期" }
        return s
    }

    private func updateCodexUI() {
        guard let b = codexItem.button else { return }
        var tip: [String] = []
        if let u = codexUsage {
            var dispRemaining: Double? = nil
            var dispReset: Date? = nil
            if codexHovering, let w = u.weeklyRemaining {
                dispRemaining = w; dispReset = u.weeklyReset
            } else if let s = u.sessionRemaining {
                dispRemaining = s; dispReset = u.sessionReset
            } else {
                dispRemaining = u.weeklyRemaining; dispReset = u.weeklyReset
            }
            b.image = ringIconImage(remaining: dispRemaining, icon: codexAppIcon)
            if let r = dispRemaining {
                b.title = "\(Int(r.rounded()))%" + (dispReset.map { " · " + compactCountdown($0.timeIntervalSinceNow) } ?? "")
            } else { b.title = "--" }
            var lenCands: [String] = []
            if let s = u.sessionRemaining { lenCands.append("\(Int(s.rounded()))%" + (u.sessionReset.map { " · " + compactCountdown($0.timeIntervalSinceNow) } ?? "")) }
            if let wk = u.weeklyRemaining { lenCands.append("\(Int(wk.rounded()))%" + (u.weeklyReset.map { " · " + compactCountdown($0.timeIntervalSinceNow) } ?? "")) }
            if !lenCands.isEmpty { fitItemLength(codexItem, candidates: lenCands) }
            cxSessionRow.setData(title: "会话（5 小时）", remaining: u.sessionRemaining, sub: resetSub(u.sessionReset))
            let (bt, urgent) = burnInfo()
            cxBurn.stringValue = bt
            cxBurn.textColor = urgent ? .systemOrange : .secondaryLabelColor
            if !bt.isEmpty { tip.append("会话：\(bt)") }
            cxWeeklyRow.setData(title: "每周", remaining: u.weeklyRemaining, sub: resetSub(u.weeklyReset))
            let (wt, wurgent) = weeklyBurnInfo()
            cxWeekBurn.stringValue = wt
            cxWeekBurn.textColor = wurgent ? .systemOrange : .secondaryLabelColor
            if !wt.isEmpty { tip.append("每周：\(wt)") }
            if let s = u.sessionRemaining { tip.append("会话（5h）剩余 \(Int(s.rounded()))%" + (u.sessionReset.map { " · \(fmtReset($0)) 重置" } ?? "")) }
            if let w = u.weeklyRemaining { tip.append("每周剩余 \(Int(w.rounded()))%" + (u.weeklyReset.map { " · \(fmtReset($0)) 重置" } ?? "")) }
        } else {
            b.image = ringIconImage(remaining: nil, icon: codexAppIcon)
            b.title = codexStatus.hasPrefix("登录已过期") ? "过期" : "--"
            fitItemLength(codexItem, candidates: [b.title])
            cxSessionRow.setData(title: "会话（5 小时）", remaining: nil, sub: codexStatus)
            cxBurn.stringValue = ""
            cxWeeklyRow.setData(title: "每周", remaining: nil, sub: "")
            cxWeekBurn.stringValue = ""
            tip.append(codexStatus)
        }
        let ct = creditsText()
        cxCredits.stringValue = ct
        if !ct.isEmpty { tip.append(ct) }
        if statsUpdated != nil {
            cxToday.stringValue = "今日　\(fmtTokens(todayStat.tokens)) tokens · \(fmtMoney(todayStat.cost))"
            cxWeek.stringValue = "近 7 天　\(fmtTokens(weekStat.tokens)) tokens · \(fmtMoney(weekStat.cost))"
            tip.append(cxToday.stringValue)
            tip.append(cxWeek.stringValue)
        } else {
            cxToday.stringValue = "今日　统计中…"
            cxWeek.stringValue = ""
        }
        let df = DateFormatter(); df.dateFormat = "HH:mm"
        cxUpdated.stringValue = "上次更新 \(df.string(from: lastCodexFetch))"
        let pname = UserDefaults.standard.string(forKey: "qm_ping_thread_name") ?? ""
        pingTarget.stringValue = pname.isEmpty ? "目标对话：未选择" : "目标对话：\(pname)"
        pingAuto.state = UserDefaults.standard.bool(forKey: "qm_ping_auto") ? .on : .off
        pingAutoWeekly.state = UserDefaults.standard.bool(forKey: "qm_ping_auto_weekly") ? .on : .off
        digestSwitch.state = UserDefaults.standard.bool(forKey: "qm_digest_on") ? .on : .off
        renderPingHistory()
        cxBurn.isHidden = cxBurn.stringValue.isEmpty
        cxWeekBurn.isHidden = cxWeekBurn.stringValue.isEmpty
        if !pingTouched {
            let last = UserDefaults.standard.double(forKey: "qm_ping_last_sent")
            if last > 0 {
                let df2 = DateFormatter(); df2.dateFormat = "M月d日 HH:mm"
                let when = df2.string(from: Date(timeIntervalSince1970: last))
                let how = UserDefaults.standard.bool(forKey: "qm_ping_last_auto") ? "自动" : "手动"
                var restored = "上次发送：\(when) · \(how)"
                if let route = UserDefaults.standard.string(forKey: "qm_ping_last_route") { restored += " · \(route)" }
                let lastTokens = UserDefaults.standard.integer(forKey: "qm_ping_last_tokens")
                if lastTokens > 0 { restored += " · \(lastTokens) tokens" }
                pingStatus.stringValue = restored
            }
        }
        b.toolTip = (["Codex"] + tip.filter { !$0.isEmpty }).joined(separator: "\n")
        syncPanelSize(codexPopover)
    }

    private func claudeExtraText(_ u: ClaudeUsage) -> String {
        var parts: [String] = []
        if let x = u.topupText {
            let core = x.split(separator: "：", maxSplits: 1).last.map(String.init) ?? x
            parts.append("额外池 " + core)
        }
        if let used = u.topupUsedPct, used >= 0.5 { parts.append("已用 \(Int(used.rounded()))%") }
        if let e = u.topupExpiry { parts.append("\(fmtDay(e)) 到期") }
        return parts.joined(separator: " · ")
    }

    private func fillClaudeRow(_ row: BarRow, extra: NSTextField, index i: Int, isPrimary: Bool, tip: inout [String]) {
        let label = claudeName(i) + (isPrimary ? "（主账号）" : "") + " · " + (claudeSurface(i) == "app" ? "应用" : "网页")
        if let u = claudeUsages[i] {
            var sub = resetSub(u.resetsAt)
            if let left = u.tokensLeftText { sub += " · \(left)" }
            row.setData(title: label, remaining: u.remaining, sub: sub)
            extra.stringValue = claudeExtraText(u)
            tip.append("\(label) 每周剩余 \(Int(u.remaining.rounded()))%" + (u.resetsAt.map { " · \(fmtReset($0)) 重置" } ?? ""))
            if !extra.stringValue.isEmpty { tip.append("\(label) \(extra.stringValue)") }
        } else if hasCookie(i) {
            row.setData(title: label, remaining: nil, sub: claudeStatuses[i])
            extra.stringValue = ""
            tip.append("\(label)：\(claudeStatuses[i])")
        } else {
            row.setData(title: label, remaining: nil, sub: i == 0 ? claudeStatuses[i] : "未设置：在「设置 Cookie…」里粘贴账号 2 的 Cookie")
            extra.stringValue = ""
        }
    }

    private func updateClaudeUI() {
        guard let b = claudeItem.button else { return }
        var tip: [String] = []
        maybeAutoSwitchClaude()
        let primary = claudePrimary
        let other = 1 - primary
        let disp = (claudeHovering && hasCookie(other)) ? other : primary
        if let u = claudeUsages[disp] {
            b.image = ringIconImage(remaining: u.remaining, icon: claudeAppIcon)
            var t = "\(Int(u.remaining.rounded()))%"
            if let r = u.resetsAt { t += " · " + compactCountdown(r.timeIntervalSinceNow) }
            if hasCookie(other), let cn = claudeCustomName(disp), let f = cn.first { t = "\(f) " + t }
            b.title = t
        } else {
            b.image = ringIconImage(remaining: nil, icon: claudeAppIcon)
            let s = claudeStatuses[disp]
            b.title = s.hasPrefix("未设置") ? "未设置" : (s.hasPrefix("登录已过期") ? "过期" : "--")
        }
        fillClaudeRow(muRow1, extra: muExtra1, index: primary, isPrimary: true, tip: &tip)
        fillClaudeRow(muRow2, extra: muExtra2, index: other, isPrimary: false, tip: &tip)
        muSwap.isHidden = !hasCookie(other)
        if hasCookie(other) { muSwap.title = "把「\(claudeName(other))」设为主账号" }
        muRowSlot = [primary, other]
        muOpen1.title = claudeSurface(primary) == "app" ? "打开应用" : "打开网页"
        muOpen2.title = claudeSurface(other) == "app" ? "打开应用" : "打开网页" 
        muAutoSwitch.state = UserDefaults.standard.bool(forKey: "qm_claude_autoswitch") ? .on : .off
        let latest = max(lastClaudeFetch[0], lastClaudeFetch[1])
        if latest == Date.distantPast {
            muUpdated.stringValue = ""
        } else {
            let df = DateFormatter(); df.dateFormat = "HH:mm"
            muUpdated.stringValue = "上次更新 \(df.string(from: latest))"
        }
        var lenCands: [String] = [b.title]
        for i in 0...1 {
            if let u = claudeUsages[i] {
                var t = "\(Int(u.remaining.rounded()))%"
                if let r = u.resetsAt { t += " · " + compactCountdown(r.timeIntervalSinceNow) }
                if hasCookie(1 - i), let cn = claudeCustomName(i), let f = cn.first { t = "\(f) " + t }
                lenCands.append(t)
            }
        }
        fitItemLength(claudeItem, candidates: lenCands)
        b.toolTip = (["Muse (muse.ai)"] + tip.filter { !$0.isEmpty }).joined(separator: "\n")
        syncPanelSize(claudePopover)
    }

}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
