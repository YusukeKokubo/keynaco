import AppKit
import UniformTypeIdentifiers

private struct BigramTransfer: Codable {
    let prev: String
    let input: String
    let output: String
    let count: Int
}

final class BigramViewController: NSViewController {
    private let tableView = DeletableTableView()
    private let deleteButton = NSButton(title: "選択を削除", target: nil, action: nil)
    private let exportButton = NSButton(title: "書き出し", target: nil, action: nil)
    private let importButton = NSButton(title: "読み込み", target: nil, action: nil)
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

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -4),
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 44),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
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

        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.target = self
        exportButton.action = #selector(exportBigram)
        bar.addSubview(exportButton)

        importButton.translatesAutoresizingMaskIntoConstraints = false
        importButton.target = self
        importButton.action = #selector(importBigram)
        bar.addSubview(importButton)

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        deleteButton.isEnabled = false
        bar.addSubview(deleteButton)

        let refreshButton = NSButton(title: "更新", target: self, action: #selector(reload))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(refreshButton)

        NSLayoutConstraint.activate([
            exportButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            exportButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            importButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            importButton.leadingAnchor.constraint(equalTo: exportButton.trailingAnchor, constant: 8),
            deleteButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
        ])
        return bar
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    @objc private func reload() {
        data = DatabaseManager.shared.fetchAllBigram()
        tableView.reloadData()
        deleteButton.isEnabled = false
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

    @objc private func exportBigram() {
        let entries = DatabaseManager.shared.fetchAllBigram()
        let payload = entries.map { BigramTransfer(prev: $0.prev, input: $0.input, output: $0.output, count: $0.count) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ykey-bigram-\(yyyyMMdd()).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) }
        catch { showAlert("書き出しに失敗しました", detail: error.localizedDescription) }
    }

    @objc private func importBigram() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let decoded = try JSONDecoder().decode([BigramTransfer].self, from: Data(contentsOf: url))
            let entries = decoded.map {
                DatabaseManager.BigramEntry(prev: $0.prev, input: $0.input, output: $0.output, count: $0.count)
            }
            let current = DatabaseManager.shared.fetchAllBigram().count
            let alert = NSAlert()
            alert.messageText = "Bi-gram を置き換えますか？"
            alert.informativeText = "現在 \(current) 件のデータをすべて削除し、インポートデータ \(entries.count) 件で置き換えます。この操作は元に戻せません。"
            alert.addButton(withTitle: "置き換える")
            alert.addButton(withTitle: "キャンセル")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            DatabaseManager.shared.replaceBigram(entries)
            reload()
        } catch { showAlert("読み込みに失敗しました", detail: error.localizedDescription) }
    }

    private func yyyyMMdd() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f.string(from: Date())
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
