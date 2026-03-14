import Cocoa

final class CandidateWindow: NSWindow {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private(set) var candidates: [String] = []
    private(set) var selectedRow: Int = 0

    var onSelect: ((String) -> Void)?

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
}

// MARK: - NSTableViewDataSource & Delegate

extension CandidateWindow: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        candidates.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = id
        cell.stringValue = candidates[row]
        cell.font = .systemFont(ofSize: 15)
        cell.textColor = .labelColor
        return cell
    }
}
