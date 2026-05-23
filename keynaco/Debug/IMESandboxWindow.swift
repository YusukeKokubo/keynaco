#if DEBUG

import AppKit
import KeynacoCore

extension Notification.Name {
    /// `InputController` が keyDown 処理完了後に内部状態を通知するときに使う（Debug のみ）。
    static let imeStateDidUpdate = Notification.Name("com.yusuke.inputmethod.keynaco.imeStateDidUpdate")
}

// MARK: - LogEntry

private struct LogEntry {
    enum Source { case ime, socket, annotation }

    let timestamp: String
    let summary: String              // リスト行に表示する1行
    let detail: String               // ディテールペインに表示する複数行
    let snapshotDict: [String: Any]  // get_log ソケットコマンド向け構造化データ
    let source: Source

    /// リスト行の先頭タグ
    var tag: String {
        switch source {
        case .ime:        return "     "   // IME は無印（最も多い）
        case .socket:     return "[AI] "
        case .annotation: return "[NOTE]"
        }
    }
}

// MARK: - IMESandboxWindow

/// 左ペイン: テキスト入力。右ペイン上: イベントリスト。右ペイン下: 選択行の詳細。
@MainActor
final class IMESandboxWindow: NSWindow, NSSplitViewDelegate,
                              NSTableViewDataSource, NSTableViewDelegate {
    static let shared = IMESandboxWindow()

    private var stateObserver: NSObjectProtocol?

    // 左右分割
    private let mainSplit = NSSplitView()
    private let leftTextView = NSTextView(frame: .zero)
    private var didSetInitialDivider = false
    private var didSetInitialRightDivider = false

    // 右ペイン内の上下分割
    private let rightSplit = NSSplitView()
    private let tableView = NSTableView()
    private let detailTextView = NSTextView(frame: .zero)

    private var entries: [LogEntry] = []

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "IME Sandbox"
        isReleasedWhenClosed = false
        setupUI()

        stateObserver = NotificationCenter.default.addObserver(
            forName: .imeStateDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let snap = note.userInfo?["snapshot"] as? InputHandlerSnapshot else { return }
            let entry = Self.makeIMEEntry(snap)
            MainActor.assumeIsolated { self?.push(entry) }
        }
    }

    // MARK: - ソケット → Sandbox（逆方向書き込み）

    /// AI がソケット経由で送ったキー操作の結果をリストに追記する。
    func appendSocketSnapshot(_ dict: [String: Any], inserted: [String]) {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm:ss"
        let ts = df.string(from: Date())

        let hiragana  = dict["composedHiragana"] as? String ?? ""
        let romaji    = dict["pendingRomaji"]    as? String ?? ""
        let candVis   = dict["candidateVisible"] as? Bool ?? false
        let row       = dict["selectedRow"]      as? Int ?? 0
        let selText   = dict["selectedText"]     as? String
        let candStr   = candVis ? "[\(row)] \(selText ?? "(nil)")" : "hidden"
        let insertStr = inserted.isEmpty ? "" : "  確定:「\(inserted.joined())」"

        let summary = "組=「\(hiragana)」romaji=「\(romaji)」  cand:\(candStr)\(insertStr)"
        let detail  = Self.formatDetailFromDict(dict, inserted: inserted, timestamp: ts)

        push(LogEntry(timestamp: ts, summary: summary, detail: detail,
                      snapshotDict: dict, source: .socket))
    }

    /// AI がアノテーション（コメント）をリストに挿入する。
    func appendAnnotation(_ text: String) {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm:ss"
        let ts = df.string(from: Date())

        push(LogEntry(timestamp: ts, summary: text, detail: text,
                      snapshotDict: [:], source: .annotation))
    }

    // MARK: - ソケット向けエクスポート

    func exportLog() -> [[String: Any]] {
        entries.map { entry in
            var dict = entry.snapshotDict
            dict["timestamp"] = entry.timestamp
            dict["summary"]   = entry.summary
            dict["source"]    = { switch entry.source {
                case .ime: return "ime"
                case .socket: return "socket"
                case .annotation: return "annotation"
            }}()
            return dict
        }
    }

    // MARK: - データ操作

    private func push(_ entry: LogEntry) {
        entries.append(entry)
        tableView.reloadData()
        let last = entries.count - 1
        tableView.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
        tableView.scrollRowToVisible(last)
        showDetail(for: last)
    }

    private func clearLog() {
        entries.removeAll()
        tableView.reloadData()
        detailTextView.string = ""
    }

    private func showDetail(for row: Int) {
        guard entries.indices.contains(row) else { return }
        detailTextView.string = entries[row].detail
        detailTextView.scrollToBeginningOfDocument(nil)
    }

    // MARK: - UI

    private func setupUI() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView = root

        mainSplit.dividerStyle = .thin
        mainSplit.isVertical = true
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        mainSplit.delegate = self

        let leftScroll = makeEditorScroll(textView: leftTextView, editable: true)

        let rightContainer = NSView()
        rightContainer.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = NSButton(title: "Clear", target: self, action: #selector(onClear))
        clearButton.bezelStyle = .rounded
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        rightSplit.dividerStyle = .thin
        rightSplit.isVertical = false
        rightSplit.translatesAutoresizingMaskIntoConstraints = false
        rightSplit.delegate = self

        let tableScroll = makeTableScroll()
        let detailScroll = makeEditorScroll(textView: detailTextView, editable: false)
        rightSplit.addSubview(tableScroll)
        rightSplit.addSubview(detailScroll)

        rightContainer.addSubview(clearButton)
        rightContainer.addSubview(rightSplit)
        NSLayoutConstraint.activate([
            clearButton.topAnchor.constraint(equalTo: rightContainer.topAnchor, constant: 4),
            clearButton.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor, constant: -8),
            clearButton.heightAnchor.constraint(equalToConstant: 24),

            rightSplit.topAnchor.constraint(equalTo: clearButton.bottomAnchor, constant: 4),
            rightSplit.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            rightSplit.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            rightSplit.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),
        ])

        mainSplit.addSubview(leftScroll)
        mainSplit.addSubview(rightContainer)

        root.addSubview(mainSplit)
        NSLayoutConstraint.activate([
            mainSplit.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainSplit.topAnchor.constraint(equalTo: root.topAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func makeEditorScroll(textView: NSTextView, editable: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = !editable
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.font = editable
            ? .systemFont(ofSize: 13)
            : .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        return scroll
    }

    private func makeTableScroll() -> NSScrollView {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("summary"))
        col.title = "イベントログ"
        col.resizingMask = .autoresizingMask

        tableView.addTableColumn(col)
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 18
        tableView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(onTableClick)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = tableView
        return scroll
    }

    @objc private func onClear() { clearLog() }
    @objc private func onTableClick() { showDetail(for: tableView.selectedRow) }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === mainSplit ? 180 : 80
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === mainSplit ? splitView.bounds.width - 300 : splitView.bounds.height - 80
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let sv = notification.object as? NSSplitView, sv === rightSplit else { return }
        guard !didSetInitialRightDivider, rightSplit.bounds.height > 0 else { return }
        didSetInitialRightDivider = true
        rightSplit.setPosition(rightSplit.bounds.height * 0.55, ofDividerAt: 0)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField
            ?? {
                let tf = NSTextField()
                tf.identifier = id
                tf.isEditable = false
                tf.isBordered = false
                tf.drawsBackground = false
                tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                return tf
            }()
        let entry = entries[row]
        cell.stringValue = "\(entry.tag) \(entry.timestamp)  \(entry.summary)"
        cell.textColor = entry.source == .annotation ? .systemOrange : .labelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showDetail(for: tableView.selectedRow)
    }

    // MARK: - show

    func show() {
        if !isVisible { center() }
        level = .floating
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !didSetInitialDivider {
            didSetInitialDivider = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.mainSplit.setPosition(self.mainSplit.bounds.width * 0.38, ofDividerAt: 0)
            }
        }
    }

    // MARK: - フォーマット（IME イベント用）

    private nonisolated static func makeIMEEntry(_ s: InputHandlerSnapshot) -> LogEntry {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm:ss"
        let ts = df.string(from: Date())
        return LogEntry(
            timestamp: ts,
            summary: formatSummaryFromSnapshot(s),
            detail: formatDetailFromSnapshot(s, timestamp: ts),
            snapshotDict: snapshotToDict(s),
            source: .ime
        )
    }

    private nonisolated static func snapshotToDict(_ s: InputHandlerSnapshot) -> [String: Any] {
        var dict: [String: Any] = [
            "composedHiragana":    s.composedHiragana,
            "pendingRomaji":       s.pendingRomaji,
            "composingText":       s.composingText,
            "markedText":          s.markedText,
            "isAsciiMode":         s.isAsciiMode,
            "isSuccessorMode":     s.isSuccessorMode,
            "isSegmentMode":       s.isSegmentMode,
            "isBracketMode":       s.isBracketMode,
            "isExplicitlySelected": s.isExplicitlySelected,
            "candidateVisible":    s.candidateVisible,
            "selectedRow":         s.selectedRow,
            "historyEnd":          s.historyEnd,
            "fixedEnd":            s.fixedEnd,
            "candidates":          s.candidates,
            "committedHistory":    s.committedHistory,
            "virtualHistoryPrefix": s.virtualHistoryPrefix,
            "segmentTexts":        s.segmentTexts,
            "focusedSegmentIndex": s.focusedSegmentIndex,
        ]
        if let st = s.selectedText { dict["selectedText"] = st }
        return dict
    }

    private nonisolated static func formatSummaryFromSnapshot(_ s: InputHandlerSnapshot) -> String {
        let modeFlags = [
            s.isAsciiMode          ? "ASCII"   : nil,
            s.isSuccessorMode      ? "Succ"    : nil,
            s.isSegmentMode        ? "Seg"     : nil,
            s.isBracketMode        ? "Brkt"    : nil,
            s.isExplicitlySelected ? "ExplSel" : nil,
        ].compactMap { $0 }.joined(separator: ",")
        let mode = modeFlags.isEmpty ? "-" : modeFlags
        let cand = s.candidateVisible ? "[\(s.selectedRow)] \(s.selectedText ?? "(nil)")" : "hidden"
        return "組=「\(s.composedHiragana)」romaji=「\(s.pendingRomaji)」  mode:\(mode)  cand:\(cand)"
    }

    private nonisolated static func formatDetailFromSnapshot(_ s: InputHandlerSnapshot, timestamp: String) -> String {
        var lines: [String] = []
        lines.append("【組成】")
        lines.append("composedHiragana : \(s.composedHiragana)")
        lines.append("pendingRomaji    : \(s.pendingRomaji)")
        lines.append("composingText    : \(s.composingText)")
        lines.append("markedText       : \(s.markedText)")
        lines.append("")
        lines.append("【モード】")
        lines.append("isAsciiMode           : \(s.isAsciiMode)")
        lines.append("isSuccessorMode       : \(s.isSuccessorMode)")
        lines.append("isSegmentMode         : \(s.isSegmentMode)")
        lines.append("isBracketMode         : \(s.isBracketMode)")
        lines.append("isExplicitlySelected  : \(s.isExplicitlySelected)")
        lines.append("")
        lines.append("【候補】")
        lines.append("visible      : \(s.candidateVisible)")
        lines.append("selectedRow  : \(s.selectedRow)")
        lines.append("selectedText : \(s.selectedText ?? "(nil)")")
        lines.append("historyEnd   : \(s.historyEnd)")
        lines.append("fixedEnd     : \(s.fixedEnd)")
        for (i, c) in s.candidates.enumerated() {
            lines.append("  [\(i)] \(c)\(i == s.selectedRow ? " ★" : "")")
        }
        lines.append("")
        lines.append("【確定履歴】")
        lines.append("committedHistory     : \(s.committedHistory)")
        lines.append("virtualHistoryPrefix : \(s.virtualHistoryPrefix)")
        if s.isSegmentMode {
            lines.append("")
            lines.append("【セグメント】")
            lines.append("segments     : \(s.segmentTexts.joined(separator: " | "))")
            lines.append("focusedIndex : \(s.focusedSegmentIndex)")
        }
        lines.append("")
        lines.append("更新: \(timestamp)  source: IME")
        return lines.joined(separator: "\n")
    }

    // MARK: - フォーマット（ソケットイベント用）

    private nonisolated static func formatDetailFromDict(
        _ dict: [String: Any],
        inserted: [String],
        timestamp: String
    ) -> String {
        func str(_ key: String) -> String { dict[key] as? String ?? "" }
        func bool(_ key: String) -> Bool  { dict[key] as? Bool ?? false }
        func int(_ key: String) -> Int    { dict[key] as? Int ?? 0 }
        func arr(_ key: String) -> [String] { dict[key] as? [String] ?? [] }

        var lines: [String] = []
        if !inserted.isEmpty {
            lines.append("【確定テキスト】")
            lines.append(inserted.map { "「\($0)」" }.joined(separator: " "))
            lines.append("")
        }
        lines.append("【組成】")
        lines.append("composedHiragana : \(str("composedHiragana"))")
        lines.append("pendingRomaji    : \(str("pendingRomaji"))")
        lines.append("composingText    : \(str("composingText"))")
        lines.append("markedText       : \(str("markedText"))")
        lines.append("")
        lines.append("【モード】")
        lines.append("isAsciiMode           : \(bool("isAsciiMode"))")
        lines.append("isSuccessorMode       : \(bool("isSuccessorMode"))")
        lines.append("isSegmentMode         : \(bool("isSegmentMode"))")
        lines.append("isBracketMode         : \(bool("isBracketMode"))")
        lines.append("isExplicitlySelected  : \(bool("isExplicitlySelected"))")
        lines.append("")
        lines.append("【候補】")
        lines.append("visible      : \(bool("candidateVisible"))")
        lines.append("selectedRow  : \(int("selectedRow"))")
        lines.append("selectedText : \(dict["selectedText"] as? String ?? "(nil)")")
        lines.append("historyEnd   : \(int("historyEnd"))")
        lines.append("fixedEnd     : \(int("fixedEnd"))")
        let cands = arr("candidates")
        let selRow = int("selectedRow")
        for (i, c) in cands.enumerated() {
            lines.append("  [\(i)] \(c)\(i == selRow ? " ★" : "")")
        }
        lines.append("")
        lines.append("【確定履歴】")
        lines.append("committedHistory : \(arr("committedHistory"))")
        lines.append("")
        lines.append("更新: \(timestamp)  source: socket(AI)")
        return lines.joined(separator: "\n")
    }
}

#endif
