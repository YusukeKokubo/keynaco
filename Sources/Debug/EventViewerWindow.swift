import AppKit

@MainActor
final class EventViewerWindow: NSWindow {
    static let shared = EventViewerWindow()

    private struct Row {
        let time: String
        let keyCode: UInt16
        let chars: String
        let baseChars: String
        let mods: String
        var consumed: String
        var action: String
        let app: String
        var candidates: [String] = []
        var selectedIdx: Int = 0
        var commitText: String? = nil
    }

    private var rows: [Row] = []
    private let maxRows = 500
    private let tableView = NSTableView()
    private var isPaused = false

    private let columnDefs: [(id: String, title: String, width: CGFloat)] = [
        ("time",     "時刻",      95),
        ("kc",       "keyCode",   55),
        ("chars",    "chars",     75),
        ("base",     "base",      75),
        ("mods",     "mods",      48),
        ("consumed", "consumed",  65),
        ("action",   "action",    100),
        ("app",      "app",       180),
    ]

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "keynaco Event Viewer"
        isReleasedWhenClosed = false
        setupUI()
    }

    private func setupUI() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView = root

        // Toolbar buttons
        let clearBtn   = button("クリア",       #selector(clearRows))
        let pauseBtn   = button("一時停止",      #selector(togglePause(_:)))
        let copyBtn    = button("コピー",        #selector(copyToClipboard))
        let exportBtn  = button("エクスポート…", #selector(exportJSONL))
        pauseBtn.setButtonType(.pushOnPushOff)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let toolbar = NSStackView(views: [clearBtn, pauseBtn, spacer, copyBtn, exportBtn])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        // Table
        for def in columnDefs {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(def.id))
            col.title = def.title
            col.width = def.width
            col.minWidth = 30
            col.resizingMask = [.userResizingMask]
            tableView.addTableColumn(col)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 18
        tableView.columnAutoresizingStyle = .noColumnAutoresizing

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        root.addSubview(sep)
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 36),

            sep.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    // MARK: - Public API

    func addEvent(keyCode: UInt16, chars: String, baseChars: String,
                  mods: NSEvent.ModifierFlags, bundleID: String?) {
        guard isVisible && !isPaused else { return }

        var modStr = ""
        if mods.contains(.command) { modStr += "⌘" }
        if mods.contains(.option)  { modStr += "⌥" }
        if mods.contains(.control) { modStr += "⌃" }
        if mods.contains(.shift)   { modStr += "⇧" }

        let appShort = bundleID.flatMap { $0.split(separator: ".").last.map(String.init) } ?? "?"
        let row = Row(
            time: timestamp(),
            keyCode: keyCode,
            chars: chars.isEmpty ? "" : chars.debugDescription,
            baseChars: baseChars.isEmpty ? "" : baseChars.debugDescription,
            mods: modStr,
            consumed: "…",
            action: "…",
            app: appShort
        )

        if rows.count >= maxRows { rows.removeFirst() }
        rows.append(row)
        tableView.reloadData()
        tableView.scrollRowToVisible(rows.count - 1)
    }

    func updateResult(consumed: Bool, action: String) {
        guard isVisible && !isPaused && !rows.isEmpty else { return }
        let idx = rows.count - 1
        rows[idx].consumed = consumed ? "✓" : "–"
        rows[idx].action = action
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: idx),
            columnIndexes: IndexSet(integersIn: 5...6)
        )
    }

    func addCandidates(_ candidates: [String], selectedIndex: Int) {
        guard isVisible && !isPaused && !rows.isEmpty else { return }
        let idx = rows.count - 1
        rows[idx].candidates = candidates
        rows[idx].selectedIdx = selectedIndex
    }

    func addCommit(_ text: String) {
        guard isVisible && !isPaused && !rows.isEmpty else { return }
        rows[rows.count - 1].commitText = text
    }

    func show() {
        if !isVisible { center() }
        level = .floating
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Actions

    @objc private func clearRows() {
        rows.removeAll()
        tableView.reloadData()
    }

    @objc private func togglePause(_ sender: NSButton) {
        isPaused = sender.state == .on
        sender.title = isPaused ? "再開" : "一時停止"
    }

    @objc private func copyToClipboard() {
        let apps = rows.map { $0.app }.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }.joined(separator: ", ")
        var lines = [
            "keynaco 入力トレース",
            "アプリ: \(apps)",
            "",
        ]
        for r in rows {
            let consumed = r.consumed == "✓" ? "消費○" : "消費×"
            let mods = r.mods.isEmpty ? "" : " [\(r.mods)]"
            lines.append("\(r.time)  kc=\(r.keyCode) \(r.chars)\(mods)  → \(r.action)  \(consumed)")
            if let ct = r.commitText {
                lines.append("         ▶ 確定: \"\(ct)\"")
            }
            if !r.candidates.isEmpty {
                let preview = r.candidates.prefix(10).enumerated().map { i, c in
                    i == r.selectedIdx ? "[\(c)]" : c
                }.joined(separator: ", ")
                let suffix = r.candidates.count > 10 ? " ...(\(r.candidates.count)件)" : ""
                lines.append("         候補: \(preview)\(suffix)")
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @objc private func exportJSONL() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("keynaco/sessions")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session-\(Int(Date().timeIntervalSince1970)).jsonl")
        let lines = rows.compactMap { r -> String? in
            var dict: [String: Any] = [
                "time": r.time, "keyCode": r.keyCode,
                "chars": r.chars, "baseChars": r.baseChars,
                "mods": r.mods, "consumed": r.consumed,
                "action": r.action, "app": r.app,
            ]
            if !r.candidates.isEmpty {
                dict["candidates"] = r.candidates
                dict["selectedIdx"] = r.selectedIdx
            }
            if let ct = r.commitText { dict["commitText"] = ct }
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let str = String(data: data, encoding: .utf8) else { return nil }
            return str
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Helpers

    private func timestamp() -> String {
        let t = Date()
        let ms = Int(t.timeIntervalSince1970 * 1000) % 1000
        let c = Calendar.current
        return String(format: "%02d:%02d:%02d.%03d",
            c.component(.hour, from: t),
            c.component(.minute, from: t),
            c.component(.second, from: t),
            ms)
    }
}

// MARK: - NSTableViewDataSource

extension EventViewerWindow: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
}

// MARK: - NSTableViewDelegate

extension EventViewerWindow: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let r = rows[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "time":     text = r.time
        case "kc":       text = String(r.keyCode)
        case "chars":    text = r.chars
        case "base":     text = r.baseChars
        case "mods":     text = r.mods
        case "consumed": text = r.consumed
        case "action":   text = r.action
        case "app":      text = r.app
        default:         text = ""
        }
        let tf = NSTextField(labelWithString: text)
        tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }
}
