import AppKit

// QuotaMeter conversation shortcuts (user-picked, any number).
// The Codex panel's "快捷对话" pull-down lists the conversations the
// user saved (it used to be its own menu-bar item; the user asked to
// fold it into the panel to save menu-bar space). Choosing one opens
// its link through NSWorkspace, which launches the handling app:
// a codex:// deep link therefore wakes the ChatGPT app and jumps
// straight to that conversation; an https://chatgpt.com link is first
// handed to the ChatGPT app and falls back to the default browser
// if the app rejects it.
// Links are stored as JSON in UserDefaults under "qm_links".
// Add links in the editor: in the ChatGPT/Codex app, use a chat's
// "copy deep link" if available, or paste the chatgpt.com URL.

struct ShortcutLink: Codable {
    var name: String
    var url: String
}

final class ShortcutsController {
    private static var editorWC: ShortcutEditorController?

    static var storedLinks: [ShortcutLink] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "qm_links"),
                  let list = try? JSONDecoder().decode([ShortcutLink].self, from: data) else { return [] }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "qm_links")
            }
            logLine("shortcuts saved n=\(newValue.count)")
        }
    }

    static func openLink(_ link: ShortcutLink) {
        let raw = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw) else { return }
        // chatgpt.com links: try the ChatGPT app first, browser as fallback.
        if let host = url.host, host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") {
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chatgpt")
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
            if let appURL = appURL {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { _, error in
                    if error != nil { NSWorkspace.shared.open(url) }
                }
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    static func openEditor() {
        let wc = ShortcutEditorController()
        editorWC = wc
        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Shortcut editor window

final class ShortcutEditorController: NSWindowController {
    private var draft: [ShortcutLink] = []
    private var nameFields: [NSTextField] = []
    private var urlFields: [NSTextField] = []
    private let stack = NSStackView()

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "管理快捷对话"
        window.center()
        self.init(window: window)
        draft = ShortcutsController.storedLinks
        let hint = NSTextField(wrappingLabelWithString: "自己挑要放进来的对话，可加多条。链接来源：Codex 本地对话在应用里对着对话用「复制深链」（codex:// 开头，点开自动唤醒应用直达）；ChatGPT 对话粘 chatgpt.com 的链接（打开时优先交给 ChatGPT 应用，接不住才回浏览器）。")
        hint.frame = NSRect(x: 16, y: 376, width: 548, height: 56)
        window.contentView?.addSubview(hint)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 64, width: 548, height: 304))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 8),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -16),
        ])
        window.contentView?.addSubview(scroll)
        let addBtn = NSButton(title: "＋ 添加一条", target: self, action: #selector(addRow))
        addBtn.bezelStyle = .rounded
        addBtn.frame = NSRect(x: 16, y: 14, width: 110, height: 28)
        window.contentView?.addSubview(addBtn)
        let saveBtn = NSButton(title: "保存", target: self, action: #selector(saveClicked))
        saveBtn.bezelStyle = .rounded; saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 484, y: 14, width: 80, height: 28)
        window.contentView?.addSubview(saveBtn)
        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: 396, y: 14, width: 80, height: 28)
        window.contentView?.addSubview(cancelBtn)
        rebuildRows()
    }

    private func harvest() {
        guard nameFields.count == draft.count, urlFields.count == draft.count else { return }
        for i in draft.indices {
            draft[i].name = nameFields[i].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            draft[i].url = urlFields[i].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func rebuildRows() {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        nameFields = []
        urlFields = []
        for (i, link) in draft.enumerated() {
            let nameF = NSTextField(string: link.name)
            nameF.placeholderString = "名称"
            nameF.translatesAutoresizingMaskIntoConstraints = false
            nameF.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let urlF = NSTextField(string: link.url)
            urlF.placeholderString = "粘贴对话链接（codex://… 或 https://chatgpt.com/…）"
            urlF.translatesAutoresizingMaskIntoConstraints = false
            urlF.widthAnchor.constraint(equalToConstant: 330).isActive = true
            let del = NSButton(title: "删除", target: self, action: #selector(deleteRow(_:)))
            del.bezelStyle = .rounded
            del.tag = i
            let row = NSStackView(views: [nameF, urlF, del])
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            stack.addArrangedSubview(row)
            nameFields.append(nameF)
            urlFields.append(urlF)
        }
    }

    @objc private func addRow() {
        harvest()
        draft.append(ShortcutLink(name: "", url: ""))
        rebuildRows()
    }

    @objc private func deleteRow(_ sender: NSButton) {
        harvest()
        guard draft.indices.contains(sender.tag) else { return }
        draft.remove(at: sender.tag)
        rebuildRows()
    }

    @objc private func saveClicked() {
        harvest()
        let cleaned = draft.filter { !$0.url.isEmpty }.map { link -> ShortcutLink in
            var l = link
            if l.name.isEmpty { l.name = "对话" }
            return l
        }
        ShortcutsController.storedLinks = cleaned
        window?.close()
    }

    @objc private func cancelClicked() { window?.close() }
}
