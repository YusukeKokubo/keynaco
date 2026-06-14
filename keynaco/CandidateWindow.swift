import Cocoa
import KeynacoCore

// MARK: - セル用のカスタムビュー

private class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private class CandidateRowView: NSView {
    let label = NSTextField(labelWithString: "")
    let deleteButton = FirstMouseButton(title: "\u{2715}", target: nil, action: nil)
    let sectionDivider = NSView()
    let sectionLabel = NSTextField(labelWithString: "")
    let zenzaiRankLabel = NSTextField(labelWithString: "")

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

        zenzaiRankLabel.font = .systemFont(ofSize: 10, weight: .medium)
        zenzaiRankLabel.textColor = NSColor.systemPurple.withAlphaComponent(0.7)
        zenzaiRankLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zenzaiRankLabel)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: zenzaiRankLabel.leadingAnchor, constant: -4),
            zenzaiRankLabel.trailingAnchor.constraint(equalTo: sectionLabel.leadingAnchor, constant: -4),
            zenzaiRankLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
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

    private let effectView = NSVisualEffectView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let progressIndicator = NSProgressIndicator()
    private var model: CandidatePanelModel?

    var onSelect: ((String) -> Void)?
    /// 削除ボタンが押された時のコールバック（候補テキスト, 行番号）
    var onDelete: ((String, Int) -> Void)?

    /// ウィンドウが画面上に出ており、候補モデルが載っている。
    var isPresented: Bool { isVisible && model != nil }

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
        effectView.material = .popover
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 6
        effectView.translatesAutoresizingMaskIntoConstraints = false

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
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(scrollView)
        effectView.addSubview(progressIndicator)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: effectView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),

            progressIndicator.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -6),
            progressIndicator.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -6),
        ])

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        container.addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: container.topAnchor),
            effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
    }

    // MARK: - Public API

    func apply(_ model: CandidatePanelModel, layout: CandidatePanelLayout) {
        switch layout {
        case .dismiss:
            dismiss()
        case .refreshInPlace:
            guard model.isPresented else {
                dismiss()
                return
            }
            let oldCount = self.model?.candidates.count ?? 0
            syncSpinner(from: model)
            let oldSnapshot = self.model.map(CandidatePanelSnapshot.init(model:))
            let newSnapshot = CandidatePanelSnapshot(model: model)
            switch CandidateTablePatchPlanner.plan(old: oldSnapshot, new: newSnapshot) {
            case .noop:
                self.model = model
                syncTableSelection()
                resizeIfCountChanged(newModel: model, oldCount: oldCount)
                return
            case .reloadAll:
                self.model = model
                tableView.reloadData()
            case .incremental(let prefix, let removeTail, let insertTail, let reloadPrefix):
                self.model = model
                applyIncrementalTablePatch(
                    prefixLength: prefix,
                    removeTailCount: removeTail,
                    insertTailCount: insertTail,
                    reloadPrefixRows: reloadPrefix
                )
            }
            resizeIfCountChanged(newModel: model, oldCount: oldCount)
            let selectionChanged = oldSnapshot?.selectedRow != model.selectedRow
            syncTableSelection()
            if selectionChanged {
                scrollSelectionIntoView()
            }
        case .selectionOnly:
            guard model.isPresented else { return }
            let oldCount = self.model?.candidates.count ?? 0
            syncSpinner(from: model)
            if let current = self.model,
               current.selectedRow == model.selectedRow,
               current.candidates == model.candidates,
               current.azooKeyFooter == model.azooKeyFooter {
                return
            }
            self.model = model
            syncTableSelection()
            tableView.scrollRowToVisible(model.selectedRow)
            resizeIfCountChanged(newModel: model, oldCount: oldCount)
        case .present(let rect):
            guard model.isPresented else {
                dismiss()
                return
            }
            self.model = model
            syncSpinner(from: model)
            presentNear(rect)
        }
    }

    private func syncSpinner(from model: CandidatePanelModel) {
        if model.azooKeyFooter == .fetching {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    private func resizeIfCountChanged(newModel: CandidatePanelModel, oldCount: Int) {
        guard isVisible, oldCount != newModel.candidates.count else { return }
        resizePreservingTop(toHeight: preferredHeight(for: newModel))
    }

    func dismiss() {
        orderOut(nil)
        model = nil
    }

    private func syncTableSelection() {
        guard let model else { return }
        tableView.selectRowIndexes(IndexSet(integer: model.selectedRow), byExtendingSelection: false)
    }

    private func preferredHeight(for model: CandidatePanelModel) -> CGFloat {
        let rowHeight = tableView.rowHeight + tableView.intercellSpacing.height
        let maxVisibleRows = 8
        let visibleCount = max(min(model.candidates.count, maxVisibleRows), 1)
        return CGFloat(visibleCount) * rowHeight + 8
    }

    /// 上端を固定したまま高さだけ変える（非同期差し替えで位置が飛ばないようにする）。
    private func resizePreservingTop(toHeight height: CGFloat) {
        var frame = self.frame
        let topY = frame.maxY
        frame.origin.y = topY - height
        frame.size.height = height
        setFrame(frame, display: true)
    }

    private func applyIncrementalTablePatch(
        prefixLength: Int,
        removeTailCount: Int,
        insertTailCount: Int,
        reloadPrefixRows: [Int]
    ) {
        guard removeTailCount > 0 || insertTailCount > 0 || !reloadPrefixRows.isEmpty else { return }
        let column = IndexSet(integer: 0)
        if removeTailCount == 0, insertTailCount == 0 {
            tableView.reloadData(forRowIndexes: IndexSet(reloadPrefixRows), columnIndexes: column)
            return
        }
        tableView.beginUpdates()
        if removeTailCount > 0 {
            tableView.removeRows(
                at: IndexSet(integersIn: prefixLength..<(prefixLength + removeTailCount)),
                withAnimation: []
            )
        }
        if insertTailCount > 0 {
            tableView.insertRows(
                at: IndexSet(integersIn: prefixLength..<(prefixLength + insertTailCount)),
                withAnimation: []
            )
        }
        if !reloadPrefixRows.isEmpty {
            tableView.reloadData(forRowIndexes: IndexSet(reloadPrefixRows), columnIndexes: column)
        }
        tableView.endUpdates()
    }

    private func scrollSelectionIntoView() {
        guard let model else { return }
        let rowHeight = tableView.rowHeight + tableView.intercellSpacing.height
        let maxVisibleRows = 8
        let scrollRow = model.candidates.count <= maxVisibleRows ? 0 : model.selectedRow
        let scrollPoint = NSPoint(x: 0, y: CGFloat(scrollRow) * rowHeight)
        scrollView.contentView.scroll(to: scrollPoint)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func presentNear(_ rect: NSRect) {
        guard let model else { return }
        tableView.reloadData()

        let height = preferredHeight(for: model)
        let width: CGFloat = 300

        var origin = NSPoint(x: rect.origin.x, y: rect.origin.y - height - 4)
        if let screen = NSScreen.main, origin.y < screen.visibleFrame.origin.y {
            origin.y = rect.maxY + 4
        }

        setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
        syncTableSelection()
        scrollSelectionIntoView()
        orderFront(nil)
    }

    @objc private func deleteButtonClicked(_ sender: NSButton) {
        let row = sender.tag
        guard let model, model.candidates.indices.contains(row) else { return }
        onDelete?(model.candidates[row], row)
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension CandidateWindow: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        model?.candidates.count ?? 0
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

        guard let model, model.candidates.indices.contains(row) else { return nil }
        rowView.label.stringValue = model.candidates[row]
        rowView.deleteButton.tag = row
        rowView.deleteButton.isHidden = !model.showsDeleteButton(at: row)
        rowView.isHistory = model.isHistoryRow(row)

        let labelText = model.sectionLabel(for: row)
        rowView.sectionLabel.stringValue = labelText
        rowView.sectionLabel.textColor = .tertiaryLabelColor
        if let rank = model.zenzaiRank(for: row) {
            rowView.zenzaiRankLabel.stringValue = "Z\(rank)"
        } else {
            rowView.zenzaiRankLabel.stringValue = ""
        }
        rowView.sectionDivider.isHidden = !model.showsSectionDivider(at: row)

        return rowView
    }
}
