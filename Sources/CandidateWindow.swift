import Cocoa

final class CandidateWindow: NSWindow {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private(set) var candidates: [String] = []
    private(set) var selectedRow: Int = 0

    var onSelect: ((String) -> Void)?
    /// 削除ボタンが押された時のコールバック（候補テキスト, 行番号）
    var onDelete: ((String, Int) -> Void)?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: [.borderless],
                   backing: .buffered, defer: true)
        self.level = .popUpMenu
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        setupViews()
    }

    private func setupViews() {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("candidate"))
        column.width = 280
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 1)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false

        effect.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        scrollView.frame = effect.bounds
        scrollView.autoresizingMask = [.width, .height]
        effect.addSubview(scrollView)

        contentView = effect
    }

    // MARK: - Public API

    func show(candidates: [String], near rect: NSRect) {
        self.candidates = candidates
        self.selectedRow = 0
        tableView.reloadData()

        let rowCount = min(candidates.count, 8)
        let height = CGFloat(rowCount) * (tableView.rowHeight + tableView.intercellSpacing.height) + 8
        let width: CGFloat = 300

        var origin = NSPoint(x: rect.origin.x, y: rect.origin.y - height - 4)
        // 画面下にはみ出す場合は上に表示
        if let screen = NSScreen.main, origin.y < screen.visibleFrame.origin.y {
            origin.y = rect.maxY + 4
        }

        setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
        orderFront(nil)
    }

    func dismiss() {
        orderOut(nil)
        candidates = []
        selectedRow = 0
    }

    func selectNext() {
        guard !candidates.isEmpty else { return }
        selectedRow = (selectedRow + 1) % candidates.count
        tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedRow)
    }

    func selectPrev() {
        guard !candidates.isEmpty else { return }
        selectedRow = (selectedRow - 1 + candidates.count) % candidates.count
        tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedRow)
    }

    func selectedText() -> String? {
        guard selectedRow >= 0, selectedRow < candidates.count else { return nil }
        return candidates[selectedRow]
    }

    /// 指定行を候補リストから削除してテーブルを更新
    func removeCandidate(at row: Int) {
        guard row >= 0, row < candidates.count else { return }
        candidates.remove(at: row)
        tableView.reloadData()
        if candidates.isEmpty {
            dismiss()
            return
        }
        selectedRow = min(selectedRow, candidates.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
    }

    @objc private func deleteButtonClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < candidates.count else { return }
        let text = candidates[row]
        onDelete?(text, row)
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension CandidateWindow: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        candidates.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("candidateRow")
        let container: NSView
        let label: NSTextField
        let button: NSButton

        if let existing = tableView.makeView(withIdentifier: id, owner: nil) {
            container = existing
            label = container.subviews.compactMap { $0 as? NSTextField }.first!
            button = container.subviews.compactMap { $0 as? NSButton }.first!
        } else {
            container = NSView()
            container.identifier = id

            label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 15)
            label.textColor = .labelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)

            button = NSButton(title: "\u{2715}", target: self, action: #selector(deleteButtonClicked(_:)))
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            container.addSubview(button)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -4),
            ])
        }

        label.stringValue = candidates[row]
        button.tag = row
        // 先頭（ひらがな候補）は削除ボタン非表示
        button.isHidden = (row == 0)

        return container
    }
}
