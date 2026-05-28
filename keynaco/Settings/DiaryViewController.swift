import AppKit
import FoundationModels
import KeynacoCore

@MainActor
final class DiaryViewController: NSViewController, NSSplitViewDelegate {
    private let datePicker = NSDatePicker()
    private let entryCountLabel = NSTextField(labelWithString: "")
    private let generateButton = NSButton(title: "日記を生成", target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")

    // 左ペイン（生ログ）
    private let rawLogLabel = NSTextField(labelWithString: "入力ログ（素材）")
    private let rawLogTableView = NSTableView()
    private var logEntries: [DatabaseManager.DailyLogEntry] = []

    // 右ペイン（生成日記）
    private let diaryView = NSTextView(frame: .zero)
    private let diaryLabel = NSTextField(labelWithString: "生成された日記")

    private weak var splitView: NSSplitView?
    private var splitPositionSet = false
    private let copyButton = NSButton(title: "コピー", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)

    private var generateTask: Task<Void, Never>?

    override func loadView() {
        view = NSView()

        setupDatePicker()
        let topBar = makeTopBar()
        view.addSubview(topBar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        view.addSubview(statusLabel)

        let sv = makeSplitView()
        splitView = sv
        view.addSubview(sv)
        let splitView = sv

        let bottomBar = makeBottomBar()
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            topBar.heightAnchor.constraint(equalToConstant: 32),

            statusLabel.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            splitView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            splitView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -4),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 44),

            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 680),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 380),
        ])
    }

    private func setupDatePicker() {
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay]
        datePicker.dateValue = Date()
        datePicker.target = self
        datePicker.action = #selector(dateChanged)
    }

    private func makeTopBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        let dateLabel = NSTextField(labelWithString: "対象日:")
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        datePicker.translatesAutoresizingMaskIntoConstraints = false

        entryCountLabel.translatesAutoresizingMaskIntoConstraints = false
        entryCountLabel.textColor = .secondaryLabelColor
        entryCountLabel.font = .systemFont(ofSize: 11)

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.isIndeterminate = true
        progressIndicator.isHidden = true
        progressIndicator.controlSize = .small

        generateButton.translatesAutoresizingMaskIntoConstraints = false
        generateButton.bezelStyle = .rounded
        generateButton.target = self
        generateButton.action = #selector(generate)

        bar.addSubview(dateLabel)
        bar.addSubview(datePicker)
        bar.addSubview(entryCountLabel)
        bar.addSubview(progressIndicator)
        bar.addSubview(generateButton)

        NSLayoutConstraint.activate([
            dateLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            dateLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor),

            datePicker.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            datePicker.leadingAnchor.constraint(equalTo: dateLabel.trailingAnchor, constant: 6),

            entryCountLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            entryCountLabel.leadingAnchor.constraint(equalTo: datePicker.trailingAnchor, constant: 8),

            progressIndicator.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: generateButton.leadingAnchor, constant: -8),

            generateButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            generateButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        ])
        return bar
    }

    private func makeLogTableView() -> NSScrollView {
        let timeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeCol.title = "時刻"
        timeCol.width = 48
        timeCol.minWidth = 48
        timeCol.maxWidth = 48
        timeCol.resizingMask = []

        let appCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appCol.title = "アプリ"
        appCol.width = 96
        appCol.minWidth = 60

        let textCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textCol.title = "テキスト"
        textCol.minWidth = 80
        textCol.resizingMask = .autoresizingMask

        rawLogTableView.addTableColumn(timeCol)
        rawLogTableView.addTableColumn(appCol)
        rawLogTableView.addTableColumn(textCol)

        rawLogTableView.dataSource = self
        rawLogTableView.delegate = self
        rawLogTableView.rowHeight = 20
        rawLogTableView.usesAlternatingRowBackgroundColors = true
        rawLogTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        rawLogTableView.selectionHighlightStyle = .none
        rawLogTableView.focusRingType = .none

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        sv.documentView = rawLogTableView
        return sv
    }

    private func makeScrolledTextView(_ tv: NSTextView) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 12)
        tv.textContainerInset = NSSize(width: 5, height: 5)
        tv.autoresizingMask = [.width]
        sv.documentView = tv
        return sv
    }

    private func makeSplitView() -> NSSplitView {
        let split = NSSplitView()
        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = true
        split.dividerStyle = .thin

        // 左ペイン
        let leftPane = NSView()
        rawLogLabel.translatesAutoresizingMaskIntoConstraints = false
        rawLogLabel.font = .systemFont(ofSize: 11, weight: .medium)
        rawLogLabel.textColor = .secondaryLabelColor
        let leftScroll = makeLogTableView()
        leftScroll.translatesAutoresizingMaskIntoConstraints = false
        leftPane.addSubview(rawLogLabel)
        leftPane.addSubview(leftScroll)
        NSLayoutConstraint.activate([
            rawLogLabel.topAnchor.constraint(equalTo: leftPane.topAnchor, constant: 2),
            rawLogLabel.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor, constant: 2),
            leftScroll.topAnchor.constraint(equalTo: rawLogLabel.bottomAnchor, constant: 2),
            leftScroll.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            leftScroll.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            leftScroll.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor),
        ])

        // 右ペイン
        let rightPane = NSView()
        diaryLabel.translatesAutoresizingMaskIntoConstraints = false
        diaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        diaryLabel.textColor = .secondaryLabelColor
        let rightScroll = makeScrolledTextView(diaryView)
        diaryView.font = .systemFont(ofSize: 13)
        rightScroll.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(diaryLabel)
        rightPane.addSubview(rightScroll)
        NSLayoutConstraint.activate([
            diaryLabel.topAnchor.constraint(equalTo: rightPane.topAnchor, constant: 2),
            diaryLabel.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor, constant: 2),
            rightScroll.topAnchor.constraint(equalTo: diaryLabel.bottomAnchor, constant: 2),
            rightScroll.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            rightScroll.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            rightScroll.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
        ])

        split.addArrangedSubview(leftPane)
        split.addArrangedSubview(rightPane)
        split.delegate = self
        return split
    }

    private func makeBottomBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyText)
        copyButton.isEnabled = false

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveDiary)
        saveButton.isEnabled = false

        bar.addSubview(copyButton)
        bar.addSubview(saveButton)

        NSLayoutConstraint.activate([
            saveButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),

            copyButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
        ])
        return bar
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshRawLog()
        loadSavedDiary()
        checkAvailability()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !splitPositionSet, let sv = splitView, sv.frame.width > 0 else { return }
        splitPositionSet = true
        sv.setPosition(sv.frame.width / 2, ofDividerAt: 0)
    }

    // MARK: - NSSplitViewDelegate

    nonisolated func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 180
    }

    nonisolated func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return proposedMaximumPosition - 180
    }

    @objc private func dateChanged() {
        refreshRawLog()
        loadSavedDiary()
    }

    private func refreshRawLog() {
        let dateStr = DatabaseManager.dateString(from: datePicker.dateValue)
        logEntries = DatabaseManager.shared.fetchDailyLog(for: dateStr)
        entryCountLabel.stringValue = logEntries.isEmpty ? "（入力ログなし）" : "（\(logEntries.count) 件）"
        rawLogTableView.reloadData()
    }

    private func loadSavedDiary() {
        let dateStr = DatabaseManager.dateString(from: datePicker.dateValue)
        if let saved = DatabaseManager.shared.fetchDiary(for: dateStr) {
            diaryView.string = saved
            copyButton.isEnabled = true
            saveButton.isEnabled = false
            statusLabel.stringValue = "保存済みの日記を表示中"
        } else {
            diaryView.string = ""
            copyButton.isEnabled = false
            saveButton.isEnabled = false
            statusLabel.stringValue = ""
        }
    }

    private func checkAvailability() {
        guard case .available = SystemLanguageModel.default.availability else {
            generateButton.isEnabled = false
            statusLabel.stringValue = "Apple Intelligence が利用できません。システム設定で有効にしてください。"
            return
        }
        generateButton.isEnabled = true
    }

    @objc private func generate() {
        generateTask?.cancel()
        generateButton.isEnabled = false
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        copyButton.isEnabled = false
        saveButton.isEnabled = false
        diaryView.string = ""

        let dateStr = DatabaseManager.dateString(from: datePicker.dateValue)
        statusLabel.stringValue = "生成中..."

        generateTask = Task { @MainActor in
            defer {
                progressIndicator.stopAnimation(nil)
                progressIndicator.isHidden = true
                generateButton.isEnabled = true
            }
            do {
                let entries = DatabaseManager.shared.fetchDailyLog(for: dateStr)
                logEntries = entries
                entryCountLabel.stringValue = entries.isEmpty ? "（入力ログなし）" : "（\(entries.count) 件）"
                rawLogTableView.reloadData()

                let result = try await DiaryGenerator.generate(for: dateStr, from: entries)
                diaryView.string = result
                copyButton.isEnabled = true
                saveButton.isEnabled = true
                statusLabel.stringValue = "生成完了（\(entries.count) 件の入力ログを使用）"
            } catch {
                statusLabel.stringValue = "エラー: \(error.localizedDescription)"
            }
        }
    }

    @objc private func copyText() {
        guard !diaryView.string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diaryView.string, forType: .string)
        statusLabel.stringValue = "クリップボードにコピーしました"
    }

    @objc private func saveDiary() {
        guard !diaryView.string.isEmpty else { return }
        let dateStr = DatabaseManager.dateString(from: datePicker.dateValue)
        DatabaseManager.shared.saveDiary(date: dateStr, content: diaryView.string)
        saveButton.isEnabled = false
        statusLabel.stringValue = "保存しました"
    }

    private static func formattedTime(epoch: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "ja_JP")
        return f.string(from: date)
    }

    private static func appDisplayName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension DiaryViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        logEntries.isEmpty ? 1 : logEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: "")
        cell.font = .systemFont(ofSize: 12)
        cell.lineBreakMode = .byTruncatingTail

        if logEntries.isEmpty {
            if tableColumn?.identifier.rawValue == "text" {
                cell.stringValue = "（まだ入力ログがありません）"
                cell.textColor = .secondaryLabelColor
            }
            return cell
        }

        let entry = logEntries[row]
        switch tableColumn?.identifier.rawValue {
        case "time":
            cell.stringValue = Self.formattedTime(epoch: entry.createdAt)
            cell.textColor = .secondaryLabelColor
            cell.alignment = .right
        case "app":
            let name = entry.appBundleID.flatMap { Self.appDisplayName(bundleID: $0) }
                ?? entry.appBundleID.map { String($0.split(separator: ".").last ?? "") }
                ?? ""
            cell.stringValue = name
            cell.textColor = .secondaryLabelColor
        case "text":
            cell.stringValue = entry.text
            cell.textColor = .labelColor
        default:
            break
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
