#if DEBUG

import AppKit
import KeynacoCore

extension Notification.Name {
    /// `InputController` が keyDown 処理完了後に内部状態を通知するときに使う（Debug のみ）。
    static let imeStateDidUpdate = Notification.Name("com.yusuke.inputmethod.keynaco.imeStateDidUpdate")
    /// `IMKTextInputAdapter.insertText` で確定テキストが挿入されたとき（Debug のみ）。
    static let imeSandboxInsertText = Notification.Name("com.yusuke.inputmethod.keynaco.imeSandboxInsertText")
}

// MARK: - SandboxLine

private struct SandboxLine {
    let index: Int
    var committedSegments: [String]
    var events: [LogEntry]

    var displayText: String { committedSegments.joined() }
}

// MARK: - LogEntry

private struct LogEntry {
    enum Source { case ime, socket, annotation }

    let lineIndex: Int
    let timestamp: String
    let summary: String
    let detail: String
    let snapshotDict: [String: Any]
    let source: Source

    var tag: String {
        switch source {
        case .ime:        return "     "
        case .socket:     return "[AI] "
        case .annotation: return "[NOTE]"
        }
    }
}

// MARK: - CopyableTableView

private final class CopyableTableView: NSTableView {
    var textForRow: ((Int) -> String?)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            let texts = selectedRowIndexes.compactMap { textForRow?($0) }
            if !texts.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(texts.joined(separator: "\n"), forType: .string)
                return
            }
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        let row = self.row(at: pt)
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let menu = NSMenu()
        let item = NSMenuItem(title: "コピー", action: #selector(copyClickedRow), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func copyClickedRow() {
        let row = clickedRow >= 0 ? clickedRow : selectedRow
        guard row >= 0, let text = textForRow?(row) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - SandboxLineRowView

/// 現在入力中の行を背景色で示す。`backgroundColor` だけでは描画されないため `drawBackground` を使う。
private final class SandboxLineRowView: NSTableRowView {
    var isCurrentLine = false {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isCurrentLine, !isSelected else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
    }
}

// MARK: - SandboxInputField

/// 不可視の入力フィールド。Enter で行を区切る。
private final class SandboxInputField: NSTextField {
    weak var sandbox: IMESandboxWindow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        focusRingType = .none
        font = .systemFont(ofSize: 13)
        placeholderString = "ここに入力…"
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

extension SandboxInputField: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        guard let sandbox else { return false }
        if sandbox.isComposing {
            sandbox.pendingLineAdvance = true
            return false
        }
        sandbox.finishCurrentLine()
        return true
    }
}

// MARK: - SandboxFocusView

/// 左ペイン最下部の入力バー。行一覧と重ならないよう配置する。
private final class SandboxFocusView: NSView {
    let inputField = SandboxInputField(frame: .zero)

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        inputField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputField)
        NSLayoutConstraint.activate([
            inputField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            inputField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            inputField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            inputField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(inputField) ?? false
    }
}

// MARK: - IMESandboxWindow

/// 左ペイン: 行一覧 + 入力フィールド。右ペイン上: イベントリスト。右ペイン下: 詳細。
@MainActor
final class IMESandboxWindow: NSWindow, NSSplitViewDelegate,
                              NSTableViewDataSource, NSTableViewDelegate {
    static let shared = IMESandboxWindow()

    private var stateObserver: NSObjectProtocol?
    private var insertTextObserver: NSObjectProtocol?

    private let mainSplit = NSSplitView()
    private let leftContainer = NSView()
    private let lineTableView = CopyableTableView()
    private let focusView = SandboxFocusView(frame: .zero)
    private var didSetInitialDivider = false
    private var didSetInitialRightDivider = false

    private let rightSplit = NSSplitView()
    private let eventTableView = NSTableView()
    private let detailTextView = NSTextView(frame: .zero)
    private let showAllLogButton = NSButton()

    private var lines: [SandboxLine] = [SandboxLine(index: 0, committedSegments: [], events: [])]
    var currentLineIndex: Int = 0
    var pendingLineAdvance = false
    private var showAllLog = false
    private var lastSnapshot: InputHandlerSnapshot?

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "IME Sandbox"
        isReleasedWhenClosed = false
        focusView.inputField.sandbox = self
        setupUI()

        stateObserver = NotificationCenter.default.addObserver(
            forName: .imeStateDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let snap = note.userInfo?["snapshot"] as? InputHandlerSnapshot else { return }
            let entry = Self.makeIMEEntry(snap, lineIndex: self?.currentLineIndex ?? 0)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastSnapshot = snap
                self.push(entry)
                if self.pendingLineAdvance, !Self.isComposing(snap) {
                    self.pendingLineAdvance = false
                    self.finishCurrentLine()
                }
            }
        }

        insertTextObserver = NotificationCenter.default.addObserver(
            forName: .imeSandboxInsertText,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let text = note.userInfo?["text"] as? String, !text.isEmpty else { return }
            MainActor.assumeIsolated { self?.appendToCurrentLine(text) }
        }
    }

    var isComposing: Bool {
        guard let s = lastSnapshot else { return false }
        return Self.isComposing(s)
    }

    private static func isComposing(_ s: InputHandlerSnapshot) -> Bool {
        !s.composedHiragana.isEmpty || !s.composingText.isEmpty || !s.pendingRomaji.isEmpty
    }

    // MARK: - ソケット → Sandbox

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

        var summary = "組=「\(hiragana)」romaji=「\(romaji)」  cand:\(candStr)\(insertStr)"
        summary += Self.candidateEventSuffix(from: dict)
        let detail  = Self.formatDetailFromDict(dict, inserted: inserted, timestamp: ts)

        push(LogEntry(
            lineIndex: currentLineIndex,
            timestamp: ts,
            summary: summary,
            detail: detail,
            snapshotDict: dict,
            source: .socket
        ))
        for text in inserted where !text.isEmpty {
            appendToCurrentLine(text)
        }
    }

    func appendAnnotation(_ text: String) {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm:ss"
        let ts = df.string(from: Date())

        push(LogEntry(
            lineIndex: currentLineIndex,
            timestamp: ts,
            summary: text,
            detail: text,
            snapshotDict: [:],
            source: .annotation
        ))
    }

    func exportLog(line: Int? = nil) -> [[String: Any]] {
        let target: [SandboxLine]
        if let line {
            target = lines.filter { $0.index == line }
        } else {
            target = lines
        }
        return target.map { sandboxLine in
            [
                "lineIndex": sandboxLine.index,
                "displayText": sandboxLine.displayText,
                "events": sandboxLine.events.map { Self.entryToDict($0) },
            ]
        }
    }

    // MARK: - データ操作

    private func refreshCurrentLineHighlight() {
        for row in 0..<lineTableView.numberOfRows {
            guard let rowView = lineTableView.rowView(atRow: row, makeIfNecessary: false) as? SandboxLineRowView else {
                continue
            }
            rowView.isCurrentLine = (row == currentLineIndex)
        }
    }

    func finishCurrentLine() {
        let nextIndex = lines.count
        lines.append(SandboxLine(index: nextIndex, committedSegments: [], events: []))
        currentLineIndex = nextIndex
        lineTableView.reloadData()
        selectLine(nextIndex)
        refreshCurrentLineHighlight()
        reloadEventTable()
        restoreInputFocus()
    }

    func appendToCurrentLine(_ text: String) {
        guard lines.indices.contains(currentLineIndex) else { return }
        lines[currentLineIndex].committedSegments.append(text)
        lineTableView.reloadData(forRowIndexes: IndexSet(integer: currentLineIndex), columnIndexes: IndexSet(integer: 0))
    }

    private func push(_ entry: LogEntry) {
        guard lines.indices.contains(currentLineIndex) else { return }
        lines[currentLineIndex].events.append(entry)
        reloadEventTable()
        if shouldAutoScrollEvents(for: entry.lineIndex) {
            scrollEventTableToLast()
            showEventDetail(at: filteredEntries.count - 1)
        }
    }

    private func shouldAutoScrollEvents(for lineIndex: Int) -> Bool {
        showAllLog || selectedLineIndex == lineIndex
    }

    private var selectedLineIndex: Int {
        let row = lineTableView.selectedRow
        if row >= 0, row < lines.count { return row }
        return currentLineIndex
    }

    private var filteredEntries: [(lineIndex: Int, entry: LogEntry)] {
        if showAllLog {
            return lines.flatMap { line in
                line.events.map { (line.index, $0) }
            }
        }
        guard lines.indices.contains(selectedLineIndex) else { return [] }
        return lines[selectedLineIndex].events.map { (selectedLineIndex, $0) }
    }

    private func clearLog() { clearSandbox() }

    /// 行・イベントログをすべてクリアする（reset コマンド・Clear ボタン用）。
    func clearSandbox() {
        lines = [SandboxLine(index: 0, committedSegments: [], events: [])]
        currentLineIndex = 0
        pendingLineAdvance = false
        lastSnapshot = nil
        lineTableView.reloadData()
        selectLine(0)
        refreshCurrentLineHighlight()
        reloadEventTable()
        detailTextView.string = ""
        restoreInputFocus()
    }

    private func selectLine(_ index: Int) {
        guard index >= 0, index < lines.count else { return }
        lineTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        lineTableView.scrollRowToVisible(index)
    }

    /// 行一覧クリック等でフォーカスが外れたあと、IME 入力用フィールドへ戻す。
    private func restoreInputFocus() {
        guard isKeyWindow else { return }
        makeFirstResponder(focusView.inputField)
    }

    private func reloadEventTable() {
        eventTableView.reloadData()
    }

    private func scrollEventTableToLast() {
        let count = filteredEntries.count
        guard count > 0 else { return }
        let last = count - 1
        eventTableView.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
        eventTableView.scrollRowToVisible(last)
    }

    private func showEventDetail(at filteredRow: Int) {
        guard filteredEntries.indices.contains(filteredRow) else { return }
        detailTextView.string = filteredEntries[filteredRow].entry.detail
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

        leftContainer.translatesAutoresizingMaskIntoConstraints = false
        let lineScroll = makeLineTableScroll()
        focusView.translatesAutoresizingMaskIntoConstraints = false
        leftContainer.addSubview(lineScroll)
        leftContainer.addSubview(focusView)
        NSLayoutConstraint.activate([
            lineScroll.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor),
            lineScroll.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor),
            lineScroll.topAnchor.constraint(equalTo: leftContainer.topAnchor),
            lineScroll.bottomAnchor.constraint(equalTo: focusView.topAnchor),

            focusView.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor),
            focusView.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor),
            focusView.bottomAnchor.constraint(equalTo: leftContainer.bottomAnchor),
            focusView.heightAnchor.constraint(equalToConstant: 28),
        ])

        let rightContainer = NSView()
        rightContainer.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = NSButton(title: "Clear", target: self, action: #selector(onClear))
        clearButton.bezelStyle = .rounded
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        showAllLogButton.title = "全ログ"
        showAllLogButton.setButtonType(.switch)
        showAllLogButton.target = self
        showAllLogButton.action = #selector(onToggleShowAllLog)
        showAllLogButton.translatesAutoresizingMaskIntoConstraints = false

        rightSplit.dividerStyle = .thin
        rightSplit.isVertical = false
        rightSplit.translatesAutoresizingMaskIntoConstraints = false
        rightSplit.delegate = self

        let eventScroll = makeEventTableScroll()
        let detailScroll = makeEditorScroll(textView: detailTextView, editable: false)
        rightSplit.addSubview(eventScroll)
        rightSplit.addSubview(detailScroll)

        rightContainer.addSubview(clearButton)
        rightContainer.addSubview(showAllLogButton)
        rightContainer.addSubview(rightSplit)
        NSLayoutConstraint.activate([
            clearButton.topAnchor.constraint(equalTo: rightContainer.topAnchor, constant: 4),
            clearButton.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor, constant: -8),
            clearButton.heightAnchor.constraint(equalToConstant: 24),

            showAllLogButton.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            showAllLogButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -12),

            rightSplit.topAnchor.constraint(equalTo: clearButton.bottomAnchor, constant: 4),
            rightSplit.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            rightSplit.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            rightSplit.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),
        ])

        mainSplit.addSubview(leftContainer)
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

    private func makeLineTableScroll() -> NSScrollView {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        col.title = "行"
        col.resizingMask = .autoresizingMask

        lineTableView.addTableColumn(col)
        lineTableView.headerView = NSTableHeaderView()
        lineTableView.rowHeight = 22
        lineTableView.font = .systemFont(ofSize: 12)
        lineTableView.dataSource = self
        lineTableView.delegate = self
        lineTableView.target = self
        lineTableView.usesAlternatingRowBackgroundColors = true
        lineTableView.textForRow = { [weak self] row in
            guard let self, self.lines.indices.contains(row) else { return nil }
            let line = self.lines[row]
            guard !line.events.isEmpty else { return nil }
            return line.events.map { Self.formatForCopy($0) }.joined(separator: "\n")
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = lineTableView
        return scroll
    }

    private func makeEventTableScroll() -> NSScrollView {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("summary"))
        col.title = "イベントログ"
        col.resizingMask = .autoresizingMask

        eventTableView.addTableColumn(col)
        eventTableView.headerView = NSTableHeaderView()
        eventTableView.rowHeight = 18
        eventTableView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        eventTableView.dataSource = self
        eventTableView.delegate = self
        eventTableView.target = self
        eventTableView.action = #selector(onEventTableClick)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = eventTableView
        return scroll
    }

    @objc private func onClear() { clearLog() }

    @objc private func onToggleShowAllLog(_ sender: NSButton) {
        showAllLog = sender.state == .on
        reloadEventTable()
        detailTextView.string = ""
    }

    @objc private func onEventTableClick() {
        showEventDetail(at: eventTableView.selectedRow)
    }

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

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === lineTableView { return lines.count }
        return filteredEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === lineTableView {
            return lineCell(for: row)
        }
        return eventCell(for: row)
    }

    private func lineCell(for row: Int) -> NSView {
        let id = NSUserInterfaceItemIdentifier("lineCell")
        let cell = lineTableView.makeView(withIdentifier: id, owner: nil) as? NSTextField
            ?? {
                let tf = NSTextField()
                tf.identifier = id
                tf.isEditable = false
                tf.isBordered = false
                tf.drawsBackground = false
                tf.font = .systemFont(ofSize: 12)
                return tf
            }()
        guard lines.indices.contains(row) else { return cell }
        let line = lines[row]
        let num = "#\(line.index + 1)"
        let text: String
        if row == currentLineIndex, line.displayText.isEmpty {
            text = "（入力中）"
        } else if line.displayText.isEmpty {
            text = "—"
        } else {
            text = line.displayText
        }
        let badge = line.events.isEmpty ? "" : "  [\(line.events.count)]"
        cell.stringValue = "\(num)  \(text)\(badge)"
        cell.textColor = (row == currentLineIndex && line.displayText.isEmpty)
            ? .secondaryLabelColor
            : .labelColor
        return cell
    }

    private func eventCell(for row: Int) -> NSView {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = eventTableView.makeView(withIdentifier: id, owner: nil) as? NSTextField
            ?? {
                let tf = NSTextField()
                tf.identifier = id
                tf.isEditable = false
                tf.isBordered = false
                tf.drawsBackground = false
                tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                return tf
            }()
        guard filteredEntries.indices.contains(row) else { return cell }
        let item = filteredEntries[row]
        let linePrefix = showAllLog ? "[#\(item.lineIndex + 1)] " : ""
        let entry = item.entry
        cell.stringValue = "\(entry.tag)\(linePrefix)\(entry.timestamp)  \(entry.summary)"
        cell.textColor = entry.source == .annotation ? .systemOrange : .labelColor
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard tableView === lineTableView else { return nil }
        return SandboxLineRowView()
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard tableView === lineTableView,
              let rowView = rowView as? SandboxLineRowView else { return }
        rowView.isCurrentLine = (row == currentLineIndex)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTableView else { return }
        if tv === lineTableView {
            reloadEventTable()
            detailTextView.string = ""
            // 行クリックで NSTableView が first responder になるため、次 runloop で入力欄へ戻す
            DispatchQueue.main.async { [weak self] in
                self?.restoreInputFocus()
            }
            return
        }
        if tv === eventTableView {
            showEventDetail(at: tv.selectedRow)
        }
    }

    // MARK: - show

    func show() {
        if !isVisible { center() }
        level = .floating
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        selectLine(currentLineIndex)
        restoreInputFocus()
        if !didSetInitialDivider {
            didSetInitialDivider = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.mainSplit.setPosition(self.mainSplit.bounds.width * 0.38, ofDividerAt: 0)
            }
        }
    }

    // MARK: - コピー用フォーマット

    private nonisolated static func formatForCopy(_ entry: LogEntry) -> String {
        "\(entry.tag)\(entry.timestamp)  \(entry.summary)"
    }

    private nonisolated static func candidateEventSuffix(from dict: [String: Any]) -> String {
        guard dict["candidateVisible"] as? Bool == true else { return "" }

        let hEnd = dict["historyEnd"] as? Int ?? 0
        let fEnd = dict["fixedEnd"]   as? Int ?? 0
        let cands = dict["candidates"] as? [String] ?? []
        let top   = cands.prefix(5).joined(separator: " ")
        let ellipsis = cands.count > 5 ? " …" : ""
        var suffix = "  hEnd:\(hEnd) fEnd:\(fEnd)  [\(top)\(ellipsis)]"

        if let build = dict["candidateBuild"] as? [String: Any],
           let logSuffix = build["logSuffix"] as? String {
            suffix += logSuffix
        }
        return suffix
    }

    // MARK: - エクスポートヘルパ

    private nonisolated static func entryToDict(_ entry: LogEntry) -> [String: Any] {
        var dict = entry.snapshotDict
        dict["lineIndex"] = entry.lineIndex
        dict["timestamp"] = entry.timestamp
        dict["summary"] = entry.summary
        dict["source"] = { switch entry.source {
            case .ime: return "ime"
            case .socket: return "socket"
            case .annotation: return "annotation"
        }}()
        return dict
    }

    // MARK: - フォーマット（IME イベント用）

    private nonisolated static func makeIMEEntry(_ s: InputHandlerSnapshot, lineIndex: Int) -> LogEntry {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm:ss"
        let ts = df.string(from: Date())
        return LogEntry(
            lineIndex: lineIndex,
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
            "isBracketMode":       s.isBracketMode,
            "isExplicitlySelected": s.isExplicitlySelected,
            "candidateVisible":    s.candidateVisible,
            "selectedRow":         s.selectedRow,
            "historyEnd":          s.historyEnd,
            "fixedEnd":            s.fixedEnd,
            "candidates":          s.candidates,
            "committedHistory":    s.committedHistory,
            "sessionTextBuffer":   s.sessionTextBuffer,
        ]
        if let st = s.selectedText { dict["selectedText"] = st }
        if let build = s.candidateBuild { dict["candidateBuild"] = build.asDictionary() }
        return dict
    }

    private nonisolated static func formatSummaryFromSnapshot(_ s: InputHandlerSnapshot) -> String {
        let modeFlags = [
            s.isAsciiMode          ? "ASCII"   : nil,
            s.isBracketMode        ? "Brkt"    : nil,
            s.isExplicitlySelected ? "ExplSel" : nil,
        ].compactMap { $0 }.joined(separator: ",")
        let mode = modeFlags.isEmpty ? "-" : modeFlags
        let cand = s.candidateVisible ? "[\(s.selectedRow)] \(s.selectedText ?? "(nil)")" : "hidden"
        var summary = "組=「\(s.composedHiragana)」romaji=「\(s.pendingRomaji)」  mode:\(mode)  cand:\(cand)"
        summary += candidateEventSuffix(from: snapshotToDict(s))
        return summary
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
        if let build = s.candidateBuild {
            lines.append("")
            lines.append("【初期行決定】")
            lines.append("trigger                  : \(build.trigger)")
            lines.append("outcome                  : \(build.outcome.rawValue)")
            lines.append("fixedSlot                : \(build.fixedSlot)")
            lines.append("hiraganaPreferred(DB)    : \(build.hiraganaPreferred)")
            lines.append("hiraganaBuiltin          : \(build.hiraganaBuiltin)")
            lines.append("hiraganaInHistory        : \(build.hiraganaInHistory)")
            lines.append("exactMatchHighHistory    : \(build.exactMatchHighHistory)")
            lines.append("highHistory              : \(build.highHistory)")
            lines.append("userDictExact            : \(build.userDictExact)")
            lines.append("azooKeyCandidates        : \(build.azooKeyCandidates)")
            lines.append("azooKeyApiOrder          : \(build.azooKeyApiOrder)")
            lines.append("initialRowPolicy         : \(build.initialRowPolicy)")
            lines.append("initialRow               : \(build.initialRow)")
            lines.append("initialText              : \(build.initialText ?? "(nil)")")
            if s.candidateVisible, build.initialRow != s.selectedRow {
                lines.append("selectedRow≠initialRow   : \(s.selectedRow) (ユーザー操作または再構築後)")
            }
            lines.append("deferAzooKeyWhileTyping  : \(build.deferAzooKeyWhileTyping)")
            lines.append("sections                 :")
            for section in build.sections {
                lines.append("  \(section)")
            }
        }
        lines.append("")
        lines.append("【確定履歴】")
        lines.append("committedHistory     : \(s.committedHistory)")
        lines.append("")
        lines.append("更新: \(timestamp)  source: IME")
        return lines.joined(separator: "\n")
    }

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
        if let build = dict["candidateBuild"] as? [String: Any] {
            lines.append("")
            lines.append("【初期行決定】")
            func buildStr(_ key: String) -> String {
                if let s = build[key] as? String { return s }
                if let b = build[key] as? Bool { return String(b) }
                if let i = build[key] as? Int { return String(i) }
                if let a = build[key] as? [String] { return a.isEmpty ? "[]" : a.joined(separator: ", ") }
                return ""
            }
            for key in [
                "trigger", "outcome", "fixedSlot", "initialRowPolicy", "initialText",
            ] {
                let val = buildStr(key)
                if !val.isEmpty { lines.append("\(key.padding(toLength: 25, withPad: " ", startingAt: 0)): \(val)") }
            }
            for key in [
                "hiraganaPreferred", "hiraganaBuiltin", "hiraganaInHistory",
                "deferAzooKeyWhileTyping",
            ] {
                lines.append("\(key.padding(toLength: 25, withPad: " ", startingAt: 0)): \(buildStr(key))")
            }
            lines.append("initialRow               : \(buildStr("initialRow"))")
            for key in [
                "exactMatchHighHistory", "highHistory", "userDictExact",
                "azooKeyCandidates", "azooKeyApiOrder",
            ] {
                lines.append("\(key.padding(toLength: 25, withPad: " ", startingAt: 0)): \(buildStr(key))")
            }
            if let sections = build["sections"] as? [String], !sections.isEmpty {
                lines.append("sections                 :")
                for section in sections { lines.append("  \(section)") }
            }
            if let entries = dict["candidateEntries"] as? [[String: Any]], !entries.isEmpty {
                lines.append("")
                lines.append("【候補セクション】")
                for entry in entries.prefix(12) {
                    let idx = entry["index"] as? Int ?? -1
                    let text = entry["text"] as? String ?? "?"
                    let section = entry["section"] as? String ?? "?"
                    var line = "  [\(idx)] \(text) (\(section))"
                    if let rank = entry["zenzaiRank"] as? Int { line += " zenzai#\(rank)" }
                    lines.append(line)
                }
            }
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
