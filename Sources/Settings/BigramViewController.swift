import AppKit
import UniformTypeIdentifiers

private struct BigramTransfer: Codable {
    let prev: String
    let input: String
    let output: String
    let count: Int
}

private let aiPrompt = """
以下は日本語 IME の bi-gram 学習データです（JSON 配列）。
各エントリは「ある語の直後に入力された読みと確定テキスト」の記録です。

フィールド:
- prev: 直前に確定した語
- input: 読み（ひらがな）
- output: 確定テキスト
- count: 使用回数

以下の観点で整形してください：
1. 明らかな誤変換（input と output が意味的に対応していない）は削除
2. count が 1 で汎用性の低いエントリは削除
3. 重複・冗長なエントリは統合（count は合算）
4. count は相対的な重みとして調整してよい（頻繁に使うものを高くする）
5. 元の JSON と同じ構造・フィールド名で返すこと

---
"""

final class BigramViewController: NSViewController {
    private let tableView = DeletableTableView()
    private let deleteButton = NSButton(title: "選択を削除", target: nil, action: nil)

    // NSTextView.scrollableTextView() でスクロールビューとテキストビューをセットで生成する
    private let exportScrollView: NSScrollView = NSTextView.scrollableTextView()
    private let importScrollView: NSScrollView = NSTextView.scrollableTextView()
    private var exportTextView: NSTextView { exportScrollView.documentView as! NSTextView }
    private var importTextView: NSTextView { importScrollView.documentView as! NSTextView }

    private var data: [DatabaseManager.BigramEntry] = []

    override func loadView() {
        view = NSView()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        view.addSubview(scrollView)

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width) in columns {
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

        let bottomBar = makeBottomBar()
        view.addSubview(bottomBar)

        let exportSection = makeExportSection()
        view.addSubview(exportSection)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -4),
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 44),
            bottomBar.bottomAnchor.constraint(equalTo: exportSection.topAnchor),
            exportSection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            exportSection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            exportSection.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            exportSection.heightAnchor.constraint(equalToConstant: 180),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 600),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 460),
        ])
    }

    private let columns: [(String, String, CGFloat)] = [
        ("prev",   "直前の語",     170),
        ("input",  "読み",         120),
        ("output", "確定テキスト", 220),
        ("count",  "回数",          60),
    ]

    private func makeBottomBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        deleteButton.isEnabled = false
        bar.addSubview(deleteButton)

        let refreshButton = NSButton(title: "更新", target: self, action: #selector(reload))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(refreshButton)

        NSLayoutConstraint.activate([
            deleteButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
        ])
        return bar
    }

    private func makeExportSection() -> NSView {
        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(separator)

        // Export panel (left)
        let exportLabel = NSTextField(labelWithString: "Export")
        exportLabel.translatesAutoresizingMaskIntoConstraints = false
        exportLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        exportLabel.textColor = .secondaryLabelColor
        section.addSubview(exportLabel)

        exportScrollView.translatesAutoresizingMaskIntoConstraints = false
        exportScrollView.borderType = .bezelBorder
        exportTextView.isEditable = false
        exportTextView.isSelectable = true
        exportTextView.isRichText = false
        exportTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        section.addSubview(exportScrollView)

        let copyBtn = NSButton(title: "コピー", target: self, action: #selector(copyJSON))
        copyBtn.translatesAutoresizingMaskIntoConstraints = false
        copyBtn.toolTip = "AI プロンプトと JSON をクリップボードにコピー"
        section.addSubview(copyBtn)

        // Import panel (right)
        let importLabel = NSTextField(labelWithString: "Import")
        importLabel.translatesAutoresizingMaskIntoConstraints = false
        importLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        importLabel.textColor = .secondaryLabelColor
        section.addSubview(importLabel)

        importScrollView.translatesAutoresizingMaskIntoConstraints = false
        importScrollView.borderType = .bezelBorder
        importTextView.isEditable = true
        importTextView.isRichText = false
        importTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        importTextView.isAutomaticQuoteSubstitutionEnabled = false
        importTextView.isAutomaticDashSubstitutionEnabled = false
        importTextView.isAutomaticTextReplacementEnabled = false
        section.addSubview(importScrollView)

        let applyBtn = NSButton(title: "更新", target: self, action: #selector(applyJSON))
        applyBtn.translatesAutoresizingMaskIntoConstraints = false
        applyBtn.toolTip = "Import テキストエリアの JSON で bi-gram を置き換える"
        section.addSubview(applyBtn)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: section.topAnchor),
            separator.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: section.trailingAnchor),

            exportLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            exportLabel.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 12),

            exportScrollView.topAnchor.constraint(equalTo: exportLabel.bottomAnchor, constant: 4),
            exportScrollView.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 8),
            exportScrollView.trailingAnchor.constraint(equalTo: section.centerXAnchor, constant: -4),
            exportScrollView.bottomAnchor.constraint(equalTo: copyBtn.topAnchor, constant: -6),

            copyBtn.bottomAnchor.constraint(equalTo: section.bottomAnchor, constant: -8),
            copyBtn.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 12),

            importLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            importLabel.leadingAnchor.constraint(equalTo: section.centerXAnchor, constant: 4),

            importScrollView.topAnchor.constraint(equalTo: importLabel.bottomAnchor, constant: 4),
            importScrollView.leadingAnchor.constraint(equalTo: section.centerXAnchor, constant: 4),
            importScrollView.trailingAnchor.constraint(equalTo: section.trailingAnchor, constant: -8),
            importScrollView.bottomAnchor.constraint(equalTo: applyBtn.topAnchor, constant: -6),

            applyBtn.bottomAnchor.constraint(equalTo: section.bottomAnchor, constant: -8),
            applyBtn.trailingAnchor.constraint(equalTo: section.trailingAnchor, constant: -12),
        ])
        return section
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    // MARK: - Actions

    @objc private func reload() {
        data = DatabaseManager.shared.fetchAllBigram()
        tableView.reloadData()
        deleteButton.isEnabled = false

        let payload = data.map { BigramTransfer(prev: $0.prev, input: $0.input,
                                                output: $0.output, count: $0.count) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        exportTextView.string = (try? encoder.encode(payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    @objc private func deleteSelected() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        let entry = data[row]
        DatabaseManager.shared.deleteBigram(prev: entry.prev, input: entry.input, output: entry.output)
        data.remove(at: row)
        tableView.removeRows(at: IndexSet(integer: row), withAnimation: .effectFade)
        deleteButton.isEnabled = tableView.selectedRow >= 0
    }

    @objc private func copyJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(aiPrompt + exportTextView.string, forType: .string)
    }

    @objc private func applyJSON() {
        do { try applyImport(from: importTextView.string) }
        catch { showAlert("読み込みに失敗しました", detail: error.localizedDescription) }
    }

    // MARK: - Helpers

    private func extractJSON(from text: String) -> String {
        guard let start = text.firstIndex(of: "["),
              let end   = text.lastIndex(of: "]") else { return text }
        return String(text[start...end])
    }

    private func applyImport(from text: String) throws {
        let json = extractJSON(from: text)
        guard let jsonData = json.data(using: .utf8) else {
            throw NSError(domain: "ykey", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "テキストを変換できませんでした"])
        }
        let decoded = try JSONDecoder().decode([BigramTransfer].self, from: jsonData)
        let entries = decoded.map {
            DatabaseManager.BigramEntry(prev: $0.prev, input: $0.input,
                                        output: $0.output, count: $0.count)
        }
        let current = DatabaseManager.shared.fetchAllBigram().count
        let alert = NSAlert()
        alert.messageText = "Bi-gram を置き換えますか？"
        alert.informativeText = "現在 \(current) 件をすべて削除し、\(entries.count) 件で置き換えます。この操作は元に戻せません。"
        alert.addButton(withTitle: "置き換える")
        alert.addButton(withTitle: "キャンセル")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DatabaseManager.shared.replaceBigram(entries)
        reload()
    }

    private func showAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}

extension BigramViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { data.count }
}

extension BigramViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let entry = data[row]
        let text: String
        switch id.rawValue {
        case "prev":   text = entry.prev
        case "input":  text = entry.input
        case "output": text = entry.output
        case "count":  text = "\(entry.count)"
        default: return nil
        }
        let tf = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            return f
        }()
        tf.stringValue = text
        return tf
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        deleteButton.isEnabled = tableView.selectedRow >= 0
    }
}
