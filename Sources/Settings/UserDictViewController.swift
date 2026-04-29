import AppKit

@MainActor
final class UserDictViewController: NSViewController {
    private let tableView = DeletableTableView()
    private let deleteButton = NSButton(title: "選択を削除", target: nil, action: nil)
    private let readingField = NSTextField()
    private let outputField = NSTextField()
    private var data: [DatabaseManager.UserDictEntry] = []

    private let columns: [(String, String, CGFloat)] = [
        ("input",  "読み",         240),
        ("output", "登録テキスト", 340),
    ]

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
            addForm.heightAnchor.constraint(equalToConstant: 90),

            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
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

        let readingLabel = NSTextField(labelWithString: "読み:")
        readingLabel.translatesAutoresizingMaskIntoConstraints = false
        form.addSubview(readingLabel)

        readingField.translatesAutoresizingMaskIntoConstraints = false
        readingField.placeholderString = "ひらがな"
        form.addSubview(readingField)

        let outputLabel = NSTextField(labelWithString: "登録テキスト:")
        outputLabel.translatesAutoresizingMaskIntoConstraints = false
        form.addSubview(outputLabel)

        outputField.translatesAutoresizingMaskIntoConstraints = false
        outputField.placeholderString = "変換テキスト"
        form.addSubview(outputField)

        let addButton = NSButton(title: "追加", target: self, action: #selector(addEntry))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.keyEquivalent = "\r"
        form.addSubview(addButton)

        let labelWidth: CGFloat = 90

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: form.topAnchor),
            separator.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: form.trailingAnchor),

            readingLabel.leadingAnchor.constraint(equalTo: form.leadingAnchor, constant: 12),
            readingLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            readingLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            readingField.leadingAnchor.constraint(equalTo: readingLabel.trailingAnchor, constant: 8),
            readingField.centerYAnchor.constraint(equalTo: readingLabel.centerYAnchor),
            readingField.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -12),

            outputLabel.leadingAnchor.constraint(equalTo: form.leadingAnchor, constant: 12),
            outputLabel.topAnchor.constraint(equalTo: readingLabel.bottomAnchor, constant: 10),
            outputLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            outputField.leadingAnchor.constraint(equalTo: outputLabel.trailingAnchor, constant: 8),
            outputField.centerYAnchor.constraint(equalTo: outputLabel.centerYAnchor),
            outputField.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -12),

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
        data = DatabaseManager.shared.fetchAllUserDict()
        tableView.reloadData()
        deleteButton.isEnabled = false
    }

    @objc private func addEntry() {
        let reading = readingField.stringValue.trimmingCharacters(in: .whitespaces)
        let output  = outputField.stringValue.trimmingCharacters(in: .whitespaces)

        guard !reading.isEmpty else {
            showAlert("読みを入力してください", detail: "読みフィールドは空にできません。")
            return
        }
        guard isHiragana(reading) else {
            showAlert("読みはひらがなで入力してください", detail: "入力された読み: \(reading)")
            return
        }
        guard !output.isEmpty else {
            showAlert("登録テキストを入力してください", detail: "登録テキストフィールドは空にできません。")
            return
        }

        let inserted = DatabaseManager.shared.addUserDict(input: reading, output: output)
        if inserted {
            readingField.stringValue = ""
            outputField.stringValue  = ""
            reload()
        } else {
            showAlert("重複エントリ", detail: "「\(reading) → \(output)」はすでに登録されています。")
        }
    }

    @objc private func deleteSelected() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        let entry = data[row]
        DatabaseManager.shared.deleteUserDict(id: entry.id)
        data.remove(at: row)
        tableView.removeRows(at: IndexSet(integer: row), withAnimation: .effectFade)
        deleteButton.isEnabled = tableView.selectedRow >= 0
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

extension UserDictViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { data.count }
}

extension UserDictViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let entry = data[row]
        let text: String
        switch id.rawValue {
        case "input":  text = entry.input
        case "output": text = entry.output
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
