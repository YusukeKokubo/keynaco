import AppKit
import KeynacoCore

final class CleanserSheetViewController: NSViewController {
    private static let appleIntelligenceHelpURL = "https://support.apple.com/ja-jp/guide/mac-help/mchl46361784/mac"

    private let scope: CleanserScope
    private let tableView = DeletableTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let helpLinkLabel = NSTextField(wrappingLabelWithString: "")
    private let timeHintLabel = NSTextField(labelWithString: "")
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let deleteSelectedButton = NSButton(title: "選択を削除", target: nil, action: nil)
    private let deleteAllButton = NSButton(title: "フラグをすべて削除", target: nil, action: nil)
    private let scopeSegment = NSSegmentedControl(
        labels: ["1回のみ", "3回以下", "全件"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let scanButton = NSButton(title: "スキャン", target: nil, action: nil)

    private var selectedMaxCount: Int? {
        switch scopeSegment.selectedSegment {
        case 0: return 1
        case 1: return 3
        default: return nil
        }
    }

    private let cleanser = LLMCleanser()
    private var data: [FlaggedEntry] = []
    private var scanTask: Task<Void, Never>?

    init(scope: CleanserScope) {
        self.scope = scope
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var tableColumns: [(String, String, CGFloat)] {
        switch scope {
        case .history:
            return [
                ("input",   "読み",         180),
                ("output",  "確定テキスト", 200),
                ("verdict", "判定",          80),
                ("reason",  "理由",         180),
            ]
        case .bigram:
            return [
                ("prev",    "直前の語",     130),
                ("input",   "読み",         110),
                ("output",  "確定テキスト", 170),
                ("verdict", "判定",          80),
                ("reason",  "理由",         150),
            ]
        }
    }

    private var titleText: String {
        switch scope {
        case .history: return "変換履歴 AI スキャン"
        case .bigram:  return "Bi-gram AI スキャン"
        }
    }

    private var emptyText: String {
        switch scope {
        case .history: return "「スキャン」を押して変換履歴をオンデバイス AI で検査します。"
        case .bigram:  return "「スキャン」を押して Bi-gram をオンデバイス AI で検査します。"
        }
    }

    override func loadView() {
        view = NSView()

        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .boldSystemFont(ofSize: 13)
        view.addSubview(titleLabel)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.cell?.wraps = true
        statusLabel.maximumNumberOfLines = 3
        view.addSubview(statusLabel)

        helpLinkLabel.translatesAutoresizingMaskIntoConstraints = false
        helpLinkLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        helpLinkLabel.textColor = .linkColor
        helpLinkLabel.stringValue = Self.appleIntelligenceHelpURL
        helpLinkLabel.isSelectable = true
        helpLinkLabel.isHidden = true
        let linkClick = NSClickGestureRecognizer(target: self, action: #selector(openAppleIntelligenceHelp))
        helpLinkLabel.addGestureRecognizer(linkClick)
        view.addSubview(helpLinkLabel)

        timeHintLabel.translatesAutoresizingMaskIntoConstraints = false
        timeHintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        timeHintLabel.textColor = .secondaryLabelColor
        timeHintLabel.stringValue = "データ量によっては数分かかることがあります。"
        timeHintLabel.isHidden = true
        view.addSubview(timeHintLabel)

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.stringValue = emptyText
        emptyStateLabel.alignment = .center
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.font = .systemFont(ofSize: 13)
        view.addSubview(emptyStateLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        view.addSubview(scrollView)

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width) in tableColumns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = 40
            tableView.addTableColumn(col)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.onDeleteSelected = { [weak self] in self?.deleteSelected() }
        scrollView.documentView = tableView

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        view.addSubview(progressIndicator)

        let bottomBar = makeBottomBar()
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            helpLinkLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            helpLinkLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            helpLinkLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            timeHintLabel.topAnchor.constraint(equalTo: helpLinkLabel.bottomAnchor, constant: 4),
            timeHintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            timeHintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: timeHintLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -32),

            progressIndicator.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            progressIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            bottomBar.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 8),
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 44),

            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 600),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
    }

    private func makeBottomBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        deleteSelectedButton.translatesAutoresizingMaskIntoConstraints = false
        deleteSelectedButton.target = self
        deleteSelectedButton.action = #selector(deleteSelected)
        deleteSelectedButton.isEnabled = false
        bar.addSubview(deleteSelectedButton)

        deleteAllButton.translatesAutoresizingMaskIntoConstraints = false
        deleteAllButton.target = self
        deleteAllButton.action = #selector(deleteAllFlagged)
        deleteAllButton.isEnabled = false
        bar.addSubview(deleteAllButton)

        let scopeLabel = NSTextField(labelWithString: "対象:")
        scopeLabel.translatesAutoresizingMaskIntoConstraints = false
        scopeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scopeLabel.textColor = .secondaryLabelColor
        bar.addSubview(scopeLabel)

        scopeSegment.translatesAutoresizingMaskIntoConstraints = false
        scopeSegment.selectedSegment = 1
        scopeSegment.controlSize = .small
        scopeSegment.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        bar.addSubview(scopeSegment)

        scanButton.translatesAutoresizingMaskIntoConstraints = false
        scanButton.target = self
        scanButton.action = #selector(scanOrCancelTapped)
        bar.addSubview(scanButton)

        let closeButton = NSButton(title: "閉じる", target: self, action: #selector(closeTapped))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(closeButton)

        NSLayoutConstraint.activate([
            deleteSelectedButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            deleteSelectedButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),

            deleteAllButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            deleteAllButton.leadingAnchor.constraint(equalTo: deleteSelectedButton.trailingAnchor, constant: 8),

            scopeLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            scopeLabel.leadingAnchor.constraint(equalTo: deleteAllButton.trailingAnchor, constant: 16),

            scopeSegment.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            scopeSegment.leadingAnchor.constraint(equalTo: scopeLabel.trailingAnchor, constant: 4),

            scanButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            scanButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),

            closeButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
        ])
        return bar
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyAvailabilityUI()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Availability

    private func applyAvailabilityUI() {
        if LLMCleanser.isModelAvailable {
            scrollView.isHidden = false
            tableView.isHidden = false
            helpLinkLabel.isHidden = true
            statusLabel.stringValue = ""
            emptyStateLabel.isHidden = false
            scanButton.isEnabled = true
        } else {
            scrollView.isHidden = true
            tableView.isHidden = true
            timeHintLabel.isHidden = true
            helpLinkLabel.isHidden = false
            emptyStateLabel.isHidden = true
            statusLabel.stringValue = "Apple Intelligence が必要です。この Mac ではオンデバイス言語モデルを利用できません。"
            scanButton.isEnabled = false
            progressIndicator.stopAnimation(nil)
        }
    }

    @objc private func openAppleIntelligenceHelp() {
        guard let url = URL(string: Self.appleIntelligenceHelpURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Scan

    @objc private func scanOrCancelTapped() {
        if scanTask != nil {
            scanTask?.cancel()
            scanButton.title = "スキャン"
            return
        }
        guard LLMCleanser.isModelAvailable else { return }
        startScan()
    }

    private func startScan() {
        data.removeAll()
        tableView.reloadData()
        scanButton.title = "キャンセル"
        scopeSegment.isEnabled = false
        timeHintLabel.isHidden = false
        emptyStateLabel.isHidden = true
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "スキャン中（0 / 0）…"
        deleteSelectedButton.isEnabled = false
        deleteAllButton.isEnabled = false

        let maxCount = selectedMaxCount
        let scope = self.scope
        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.scanTask = nil
                self.scopeSegment.isEnabled = true
            }
            do {
                let result = try await self.cleanser.evaluate(
                    db: .shared,
                    scope: scope,
                    maxCount: maxCount,
                    onProgress: { processed, total in
                        if total == 0 {
                            self.statusLabel.stringValue = "評価対象のエントリがありません。"
                        } else {
                            self.statusLabel.stringValue = "スキャン中（\(processed) / \(total)）…"
                        }
                    },
                    onEntry: { newEntries in
                        let startRow = self.data.count
                        self.data.append(contentsOf: newEntries)
                        let indexSet = IndexSet(startRow..<self.data.count)
                        self.tableView.insertRows(at: indexSet, withAnimation: .effectFade)
                        self.deleteAllButton.isEnabled = true
                    }
                )
                if result.isEmpty {
                    self.statusLabel.stringValue = "問題のあるエントリは見つかりませんでした。"
                    self.emptyStateLabel.isHidden = false
                    self.emptyStateLabel.stringValue = "✓ 問題なし"
                } else {
                    self.statusLabel.stringValue = "LLM がフラグを立てたエントリ（\(result.count) 件）"
                    self.emptyStateLabel.isHidden = true
                }
                self.deleteAllButton.isEnabled = !result.isEmpty
                self.finishScanningUI()
            } catch is CancellationError {
                self.statusLabel.stringValue = "スキャンを中止しました。"
                self.emptyStateLabel.stringValue = self.emptyText
                self.emptyStateLabel.isHidden = self.data.isEmpty ? false : true
                self.finishScanningUI()
            } catch let err as CleanserError where err == .unavailable {
                self.statusLabel.stringValue = "Apple Intelligence が利用できなくなりました。"
                self.applyAvailabilityUI()
                self.finishScanningUI()
            } catch {
                if let window = self.view.window {
                    let alert = NSAlert()
                    alert.messageText = "エラー"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.beginSheetModal(for: window, completionHandler: nil)
                }
                self.statusLabel.stringValue = "スキャンに失敗しました。"
                self.emptyStateLabel.stringValue = self.emptyText
                self.emptyStateLabel.isHidden = self.data.isEmpty ? false : true
                self.finishScanningUI()
            }
        }
    }

    private func finishScanningUI() {
        scanButton.title = "スキャン"
        progressIndicator.stopAnimation(nil)
        timeHintLabel.isHidden = true
    }

    // MARK: - Delete

    @objc private func deleteSelected() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        let entry = data[row]
        deleteEntry(entry)
        data.remove(at: row)
        tableView.removeRows(at: IndexSet(integer: row), withAnimation: .effectFade)
        refreshAfterDelete()
    }

    @objc private func deleteAllFlagged() {
        guard !data.isEmpty else { return }
        for entry in data { deleteEntry(entry) }
        data.removeAll()
        tableView.reloadData()
        refreshAfterDelete()
    }

    private func deleteEntry(_ entry: FlaggedEntry) {
        switch entry.source {
        case let .history(input, output):
            DatabaseManager.shared.deleteHistoryEntry(input: input, output: output)
        case let .bigram(prev, input, output):
            DatabaseManager.shared.deleteBigram(prev: prev, input: input, output: output)
        }
    }

    private func refreshAfterDelete() {
        deleteSelectedButton.isEnabled = tableView.selectedRow >= 0 && !data.isEmpty
        deleteAllButton.isEnabled = !data.isEmpty
        if data.isEmpty {
            statusLabel.stringValue = "すべて削除しました。"
            emptyStateLabel.stringValue = "✓ 問題なし"
            emptyStateLabel.isHidden = false
        } else {
            statusLabel.stringValue = "LLM がフラグを立てたエントリ（\(data.count) 件）"
        }
    }

    @objc private func closeTapped() {
        scanTask?.cancel()
        dismiss(self)
    }
}

extension CleanserSheetViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { data.count }
}

extension CleanserSheetViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let entry = data[row]

        let text: String
        let textColor: NSColor?
        switch id.rawValue {
        case "prev":
            switch entry.source {
            case .history:              text = "—"
            case let .bigram(prev, _, _): text = prev
            }
            textColor = nil
        case "input":
            switch entry.source {
            case let .history(input, _):    text = input
            case let .bigram(_, input, _):  text = input
            }
            textColor = nil
        case "output":
            switch entry.source {
            case let .history(_, output):   text = output
            case let .bigram(_, _, output): text = output
            }
            textColor = nil
        case "verdict":
            switch entry.verdict {
            case .suspect: text = "⚠ suspect"; textColor = .systemOrange
            case .delete:  text = "🗑 delete";  textColor = .systemRed
            }
        case "reason":
            text = entry.reason
            textColor = nil
        default:
            return nil
        }

        let tf = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            return f
        }()
        tf.stringValue = text
        tf.textColor = textColor ?? .labelColor
        return tf
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        deleteSelectedButton.isEnabled = tableView.selectedRow >= 0
    }
}
