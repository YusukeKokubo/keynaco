import AppKit
import KeynacoCore

@MainActor
final class HiraganaPreferredViewController: NSViewController {
    private let tableView = DeletableTableView()
    private let deleteButton = NSButton(title: "選択を削除", target: nil, action: nil)
    private let wordField = NSTextField()
    private var userData: [String] = []

    private enum RowItem {
        case header(String)
        case builtin(word: String, category: String)
        case user(String)
    }
    private var rows: [RowItem] = []

    private func buildRows() {
        let builtins = HiraganaPreferredBuiltins.words
            .sorted { $0.key < $1.key }
        rows = [.header("ユーザー追加語")]
            + userData.map { .user($0) }
            + [.header("組み込み固定語")]
            + builtins.map { .builtin(word: $0.key, category: $0.value) }
    }

    override func loadView() {
        view = NSView()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        view.addSubview(scrollView)

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let wordCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("word"))
        wordCol.title = "語彙"
        wordCol.width = 160
        wordCol.minWidth = 40
        tableView.addTableColumn(wordCol)

        let categoryCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
        categoryCol.title = "分類"
        categoryCol.width = 120
        categoryCol.minWidth = 40
        tableView.addTableColumn(categoryCol)

        tableView.delegate = self
        tableView.dataSource = self
        tableView.onDeleteSelected = { [weak self] in self?.deleteSelected() }
        scrollView.documentView = tableView

        let bottomBar = makeBottomBar()
        view.addSubview(bottomBar)

        let addForm = makeAddForm()
        view.addSubview(addForm)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -4),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 44),
            bottomBar.bottomAnchor.constraint(equalTo: addForm.topAnchor),

            addForm.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            addForm.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            addForm.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            addForm.heightAnchor.constraint(equalToConstant: 60),

            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
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

    private func makeAddForm() -> NSView {
        let form = NSView()
        form.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        form.addSubview(separator)

        let wordLabel = NSTextField(labelWithString: "語彙:")
        wordLabel.translatesAutoresizingMaskIntoConstraints = false
        form.addSubview(wordLabel)

        wordField.translatesAutoresizingMaskIntoConstraints = false
        wordField.placeholderString = "ひらがな"
        form.addSubview(wordField)

        let addButton = NSButton(title: "追加", target: self, action: #selector(addEntry))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.keyEquivalent = "\r"
        form.addSubview(addButton)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: form.topAnchor),
            separator.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: form.trailingAnchor),

            wordLabel.leadingAnchor.constraint(equalTo: form.leadingAnchor, constant: 12),
            wordLabel.centerYAnchor.constraint(equalTo: form.centerYAnchor),
            wordLabel.widthAnchor.constraint(equalToConstant: 40),

            wordField.leadingAnchor.constraint(equalTo: wordLabel.trailingAnchor, constant: 8),
            wordField.centerYAnchor.constraint(equalTo: wordLabel.centerYAnchor),
            wordField.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -12),

            addButton.trailingAnchor.constraint(equalTo: form.trailingAnchor, constant: -12),
            addButton.centerYAnchor.constraint(equalTo: form.centerYAnchor),
        ])
        return form
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    @objc private func reload() {
        userData = DatabaseManager.shared.fetchAllHiraganaPreferred()
        buildRows()
        tableView.reloadData()
        deleteButton.isEnabled = false
    }

    @objc private func addEntry() {
        let word = wordField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else {
            showAlert("語彙を入力してください", detail: "語彙フィールドは空にできません。")
            return
        }
        guard isHiragana(word) else {
            showAlert("語彙はひらがなで入力してください", detail: "入力された語彙: \(word)")
            return
        }
        let inserted = DatabaseManager.shared.addHiraganaPreferred(word: word)
        if inserted {
            wordField.stringValue = ""
            reload()
            NotificationCenter.default.post(name: .keynacoHiraganaPreferredDidChange, object: nil)
        } else {
            showAlert("重複エントリ", detail: "「\(word)」はすでに登録されています。")
        }
    }

    @objc private func deleteSelected() {
        let row = tableView.selectedRow
        guard row >= 0, case .user(let word) = rows[row] else { return }
        DatabaseManager.shared.deleteHiraganaPreferred(word: word)
        reload()
        NotificationCenter.default.post(name: .keynacoHiraganaPreferredDidChange, object: nil)
    }

    private func isHiragana(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value >= 0x3041 && $0.value <= 0x309F }
    }

    private func showAlert(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension HiraganaPreferredViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
}

extension HiraganaPreferredViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .header, .builtin: return false
        case .user: return true
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue
        switch rows[row] {
        case .header(let title):
            return NSTextField(labelWithString: title)
        case .builtin(let word, let category):
            let text = id == "word" ? word : id == "category" ? category : ""
            let tf = makeCell(id: id ?? "", text: text)
            tf.textColor = .secondaryLabelColor
            return tf
        case .user(let word):
            let text = id == "word" ? word : ""
            return makeCell(id: id ?? "", text: text)
        }
    }

    private func makeCell(id: String, text: String) -> NSTextField {
        let tf = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: nil) as? NSTextField ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = NSUserInterfaceItemIdentifier(id)
            return f
        }()
        tf.stringValue = text
        tf.textColor = .labelColor
        return tf
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, case .user = rows[row] else {
            deleteButton.isEnabled = false
            return
        }
        deleteButton.isEnabled = true
    }
}
