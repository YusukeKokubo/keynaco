import AppKit
import KeynacoCore

final class HistoryViewController: NSViewController {
    private let tableView = DeletableTableView()
    private let deleteButton = NSButton(title: "選択を削除", target: nil, action: nil)
    private var data: [DatabaseManager.HistoryEntry] = []

    private struct ColumnDef {
        let id: String
        let title: String
        let minWidth: CGFloat
        let defaultWidth: CGFloat
        let sortKey: String?
    }

    private let columnDefs: [ColumnDef] = [
        ColumnDef(id: "input",   title: "読み",         minWidth: 60,  defaultWidth: 150, sortKey: nil),
        ColumnDef(id: "output",  title: "確定テキスト", minWidth: 60,  defaultWidth: 200, sortKey: nil),
        ColumnDef(id: "pos",     title: "品詞",         minWidth: 60,  defaultWidth: 90,  sortKey: "pos"),
        ColumnDef(id: "pos_tag", title: "LLMタグ",      minWidth: 60,  defaultWidth: 120, sortKey: nil),
        ColumnDef(id: "count",   title: "回数",         minWidth: 40,  defaultWidth: 60,  sortKey: "count"),
        ColumnDef(id: "used_at", title: "最終変換",     minWidth: 80,  defaultWidth: 110, sortKey: "used_at"),
    ]

    override func loadView() {
        view = NSView()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        view.addSubview(scrollView)

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .sequentialColumnAutoresizingStyle
        for def in columnDefs {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(def.id))
            col.title = def.title
            col.width = def.defaultWidth
            col.minWidth = def.minWidth
            col.resizingMask = [.userResizingMask, .autoresizingMask]
            if let key = def.sortKey {
                col.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            }
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

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    @objc private func reload() {
        data = DatabaseManager.shared.fetchAllHistory()
        applyCurrentSort()
        deleteButton.isEnabled = false
    }

    private func applyCurrentSort() {
        guard let descriptor = tableView.sortDescriptors.first else {
            tableView.reloadData()
            return
        }
        sortData(by: descriptor)
    }

    private func sortData(by descriptor: NSSortDescriptor) {
        let ascending = descriptor.ascending
        switch descriptor.key {
        case "pos":
            data.sort {
                let a = Self.posLabel($0.pos)
                let b = Self.posLabel($1.pos)
                return ascending ? a < b : a > b
            }
        case "count":
            data.sort { ascending ? $0.count < $1.count : $0.count > $1.count }
        case "used_at":
            data.sort { ascending ? $0.usedAt < $1.usedAt : $0.usedAt > $1.usedAt }
        default:
            break
        }
        tableView.reloadData()
    }

    @objc private func deleteSelected() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        let entry = data[row]
        DatabaseManager.shared.deleteHistoryEntry(input: entry.input, output: entry.output)
        data.remove(at: row)
        tableView.removeRows(at: IndexSet(integer: row), withAnimation: .effectFade)
        deleteButton.isEnabled = tableView.selectedRow >= 0
    }
}

extension HistoryViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { data.count }
}

extension HistoryViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let entry = data[row]
        let text: String
        switch id.rawValue {
        case "input":   text = entry.input
        case "output":  text = entry.output
        case "pos":     text = Self.posLabel(entry.pos)
        case "pos_tag": text = entry.posTag ?? "―"
        case "count":   text = "\(entry.count)"
        case "used_at": text = Self.formatDate(entry.usedAt)
        default: return nil
        }
        let tf = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            return f
        }()
        tf.stringValue = text
        tf.toolTip = nil
        return tf
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        sortData(by: descriptor)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        deleteButton.isEnabled = tableView.selectedRow >= 0
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    private static func formatDate(_ epoch: Int64) -> String {
        guard epoch > 0 else { return "―" }
        return dateFormatter.string(from: Date(timeIntervalSince1970: Double(epoch)))
    }

    private static func posLabel(_ pos: String?) -> String {
        switch pos {
        case "noun":                return "名詞"
        case "proper_noun":         return "固有名詞"
        case "proper_noun/place":   return "固有名詞（地名）"
        case "proper_noun/person":  return "固有名詞（人名）"
        case "proper_noun/org":     return "固有名詞（組織）"
        case "proper_noun/product":  return "固有名詞（製品）"
        case "proper_noun/work":     return "固有名詞（作品）"
        case "verb":                return "動詞"
        case "adjective":           return "形容詞"
        case "other":               return "その他"
        case "other/conjunction":   return "その他（接続詞）"
        case "other/interjection":  return "その他（感動詞）"
        case "other/clause":        return "その他（節）"
        case "other/unknown":       return "その他（不明）"
        default:                    return "―"
        }
    }
}
