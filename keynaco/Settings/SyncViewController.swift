import AppKit
import KeynacoCore

final class SyncViewController: NSViewController {

    private let pathField = NSTextField()
    private let browseButton = NSButton()
    private let syncOnQuitCheckbox = NSButton(checkboxWithTitle: "終了時に自動で書き出す", target: nil, action: nil)
    private let exportButton = NSButton()
    private let importButton = NSButton()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 280))
        setupUI()
        loadSettings()
    }

    private func setupUI() {
        let descLabel = NSTextField(wrappingLabelWithString: "NAS 上の同期先ファイルパスを指定してください。rsync でローカル DB と同期します。")
        descLabel.isEditable = false
        descLabel.isBordered = false
        descLabel.backgroundColor = .clear
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(descLabel)

        let pathLabel = NSTextField(labelWithString: "同期先パス:")
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pathLabel)

        pathField.placeholderString = "/Volumes/NAS/keynaco/history.db"
        pathField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pathField)

        browseButton.title = "選択…"
        browseButton.bezelStyle = .rounded
        browseButton.target = self
        browseButton.action = #selector(browse)
        browseButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browseButton)

        syncOnQuitCheckbox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(syncOnQuitCheckbox)

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sep)

        exportButton.title = "今すぐ書き出し（→ NAS）"
        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(exportNow)
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(exportButton)

        importButton.title = "今すぐ取り込み（NAS →）"
        importButton.bezelStyle = .rounded
        importButton.target = self
        importButton.action = #selector(importNow)
        importButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(importButton)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            descLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            descLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            descLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            pathLabel.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 20),
            pathLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            pathLabel.widthAnchor.constraint(equalToConstant: 80),

            pathField.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),
            pathField.leadingAnchor.constraint(equalTo: pathLabel.trailingAnchor, constant: 8),
            pathField.trailingAnchor.constraint(equalTo: browseButton.leadingAnchor, constant: -8),

            browseButton.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),
            browseButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            browseButton.widthAnchor.constraint(equalToConstant: 70),

            syncOnQuitCheckbox.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 12),
            syncOnQuitCheckbox.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),

            sep.topAnchor.constraint(equalTo: syncOnQuitCheckbox.bottomAnchor, constant: 20),
            sep.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sep.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            exportButton.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 16),
            exportButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            importButton.centerYAnchor.constraint(equalTo: exportButton.centerYAnchor),
            importButton.leadingAnchor.constraint(equalTo: exportButton.trailingAnchor, constant: 12),

            statusLabel.topAnchor.constraint(equalTo: exportButton.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func loadSettings() {
        pathField.stringValue = SyncSettings.nasPath ?? ""
        syncOnQuitCheckbox.state = SyncSettings.syncOnQuit ? .on : .off
    }

    func saveSettings() {
        let path = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        SyncSettings.nasPath = path.isEmpty ? nil : path
        SyncSettings.syncOnQuit = syncOnQuitCheckbox.state == .on
    }

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.title = "NAS 上の同期先フォルダを選択"
        panel.message = "SMB マウント済みの NAS 上のフォルダを選択してください。history.db はここに作成されます。"
        panel.prompt = "選択"
        if panel.runModal() == .OK, let url = panel.url {
            pathField.stringValue = url.appendingPathComponent("history.db").path
        }
    }

    @objc private func exportNow() {
        saveSettings()
        setRunning(true, message: "書き出し中…")
        SyncSettings.exportToNAS { [weak self] ok, output in
            DispatchQueue.main.async {
                self?.setRunning(false, message: ok ? "書き出し完了" : "エラー: \(output.prefix(120))")
            }
        }
    }

    @objc private func importNow() {
        saveSettings()
        let alert = NSAlert()
        alert.messageText = "DB を NAS から上書きします"
        alert.informativeText = "現在の変換履歴・ユーザー辞書は NAS のデータで置き換えられます。よろしいですか？"
        alert.addButton(withTitle: "取り込む")
        alert.addButton(withTitle: "キャンセル")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        setRunning(true, message: "取り込み中…")
        SyncSettings.importFromNAS { [weak self] ok, output in
            DispatchQueue.main.async {
                self?.setRunning(false, message: ok ? "取り込み完了" : "エラー: \(output.prefix(120))")
            }
        }
    }

    private func setRunning(_ running: Bool, message: String) {
        exportButton.isEnabled = !running
        importButton.isEnabled = !running
        statusLabel.stringValue = message
    }
}
