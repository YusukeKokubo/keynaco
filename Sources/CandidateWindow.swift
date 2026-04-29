import Cocoa

// MARK: - セル用のカスタムビュー

private class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private class CandidateRowView: NSView {
    let label = NSTextField(labelWithString: "")
    let deleteButton = FirstMouseButton(title: "\u{2715}", target: nil, action: nil)
    let sectionDivider = NSView()
    let sectionLabel = NSTextField(labelWithString: "")

    var isHistory: Bool = false {
        didSet {
            wantsLayer = true
            layer?.backgroundColor = isHistory
                ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
                : NSColor.clear.cgColor
        }
    }

    init(deleteTarget: AnyObject, deleteAction: Selector) {
        super.init(frame: .zero)

        label.font = .systemFont(ofSize: 15)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        deleteButton.target = deleteTarget
        deleteButton.action = deleteAction
        deleteButton.bezelStyle = .inline
        deleteButton.isBordered = false
        deleteButton.font = .systemFont(ofSize: 11)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(deleteButton)

        sectionDivider.wantsLayer = true
        sectionDivider.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor
        sectionDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionDivider)

        sectionLabel.font = .systemFont(ofSize: 9)
        sectionLabel.textColor = .tertiaryLabelColor
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionLabel)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: sectionLabel.leadingAnchor, constant: -4),
            sectionLabel.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -4),
            sectionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            sectionDivider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            sectionDivider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            sectionDivider.bottomAnchor.constraint(equalTo: bottomAnchor),
            sectionDivider.heightAnchor.constraint(equalToConstant: 1.5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 候補ウィンドウ

@MainActor
final class CandidateWindow: NSPanel {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private(set) var candidates: [String] = []
    private(set) var selectedRow: Int = 0
    /// ユーザーが ↑↓ で明示的に候補を動かしたか
    private(set) var isExplicitlySelected: Bool = false
    /// スクロール範囲外の固定行数（削除ボタンを非表示にする行数）
    private var fixedRowCount: Int = 0
    /// 履歴セクションの末尾インデックス（この行の後にセパレータを描画）
    private(set) var historySectionEnd: Int = 0
    /// 予測セクションの末尾インデックス（fixedRowCount <= row < predictionSectionEnd が予測行）
    private var predictionSectionEnd: Int = 0

    var onSelect: ((String) -> Void)?
    /// 削除ボタンが押された時のコールバック（候補テキスト, 行番号）
    var onDelete: ((String, Int) -> Void)?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        self.level = .popUpMenu
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces]
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

    func show(candidates: [String], historySectionEnd: Int = 0, initialRow: Int = 0, predictionEnd: Int = 0, near rect: NSRect) {
        self.candidates = candidates
        self.historySectionEnd = historySectionEnd
        self.predictionSectionEnd = predictionEnd
        self.selectedRow = candidates.isEmpty ? 0 : min(initialRow, candidates.count - 1)
        self.isExplicitlySelected = false
        self.fixedRowCount = initialRow
        tableView.reloadData()

        // initialRow より前の行（ひらがな・カタカナ）はウィンドウ高さに含めず、
        // スクロールで隠す。↑ キーで上スクロールすると現れる。
        let rowHeight = tableView.rowHeight + tableView.intercellSpacing.height
        let visibleCount = max(min(candidates.count - initialRow, 8), 1)
        let height = CGFloat(visibleCount) * rowHeight + 8
        let width: CGFloat = 300

        var origin = NSPoint(x: rect.origin.x, y: rect.origin.y - height - 4)
        // 画面下にはみ出す場合は上に表示
        if let screen = NSScreen.main, origin.y < screen.visibleFrame.origin.y {
            origin.y = rect.maxY + 4
        }

        setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
        tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        // initialRow の行がウィンドウ最上部に来るようスクロール位置を設定
        let scrollPoint = NSPoint(x: 0, y: CGFloat(initialRow) * rowHeight)
        scrollView.contentView.scroll(to: scrollPoint)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        orderFront(nil)
    }

    func dismiss() {
        orderOut(nil)
        candidates = []
        selectedRow = 0
        isExplicitlySelected = false
        fixedRowCount = 0
        historySectionEnd = 0
        predictionSectionEnd = 0
    }

    func selectNext() {
        guard !candidates.isEmpty else { return }
        selectedRow = (selectedRow + 1) % candidates.count
        isExplicitlySelected = true
        tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedRow)
    }

    func selectPrev() {
        guard !candidates.isEmpty else { return }
        selectedRow = (selectedRow - 1 + candidates.count) % candidates.count
        isExplicitlySelected = true
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
        if row < predictionSectionEnd { predictionSectionEnd -= 1 }
        if row < historySectionEnd { historySectionEnd -= 1 }
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
        let rowView: CandidateRowView

        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? CandidateRowView {
            rowView = existing
        } else {
            rowView = CandidateRowView(deleteTarget: self, deleteAction: #selector(deleteButtonClicked(_:)))
            rowView.identifier = id
        }

        rowView.label.stringValue = candidates[row]
        rowView.deleteButton.tag = row
        rowView.deleteButton.isHidden = row < fixedRowCount || row >= historySectionEnd
        rowView.isHistory = row >= predictionSectionEnd && row < historySectionEnd

        let sectionLabelText: String
        switch row {
        case fixedRowCount where row < predictionSectionEnd:      sectionLabelText = "予測"
        case predictionSectionEnd where row < historySectionEnd:  sectionLabelText = "履歴"
        case historySectionEnd where historySectionEnd < candidates.count: sectionLabelText = "辞書"
        default:                                                   sectionLabelText = ""
        }
        rowView.sectionLabel.stringValue = sectionLabelText

        let showDivider = (predictionSectionEnd > fixedRowCount && row == predictionSectionEnd - 1 && predictionSectionEnd <= historySectionEnd)
            || (row == historySectionEnd - 1 && historySectionEnd < candidates.count)
        rowView.sectionDivider.isHidden = !showDivider

        return rowView
    }
}
