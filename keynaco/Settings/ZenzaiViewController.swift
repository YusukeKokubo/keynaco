import AppKit

/// Zenzai（ニューラル仮名漢字変換）の有効化・プロフィール・推論上限。
final class ZenzaiViewController: NSViewController {

    private let enabledSwitch = NSSwitch()
    private let profileField = NSTextField()
    private let topicField = NSTextField()
    private let styleField = NSTextField()
    private let preferenceField = NSTextField()
    private let limitField = NSTextField()
    private let limitStepper = NSStepper()
    private let applyButton: NSButton = {
        let b = NSButton(title: "保存", target: nil, action: nil)
        b.bezelStyle = .rounded
        return b
    }()

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let d = UserDefaults.standard
        let row1 = rowStack(label: "Zenzai を有効にする", control: enabledSwitch)
        profileField.placeholderString = "例: ITエンジニア,技術文書"
        profileField.stringValue = d.string(forKey: ZenzaiSettings.profileKey) ?? ""
        let row2 = rowStack(label: "プロフィール", control: profileField)
        topicField.placeholderString = "例: 料理,レシピ"
        topicField.stringValue = d.string(forKey: ZenzaiSettings.topicKey) ?? ""
        let row3 = rowStack(label: "トピック", control: topicField)
        styleField.placeholderString = "例: ですます,箇条書き"
        styleField.stringValue = d.string(forKey: ZenzaiSettings.styleKey) ?? ""
        let row4 = rowStack(label: "文体", control: styleField)
        preferenceField.placeholderString = "例: 旧字体優先"
        preferenceField.stringValue = d.string(forKey: ZenzaiSettings.preferenceKey) ?? ""
        let row5 = rowStack(label: "好み", control: preferenceField)
        limitStepper.minValue = 1
        limitStepper.maxValue = 50
        limitStepper.increment = 1
        let lim = d.object(forKey: ZenzaiSettings.inferenceLimitKey) as? Int ?? 5
        limitStepper.doubleValue = Double(lim)
        limitField.isEditable = true
        limitField.alignment = .right
        limitField.stringValue = "\(lim)"
        limitStepper.target = self
        limitStepper.action = #selector(stepperChanged)
        let limitRow = NSStackView(views: [label("推論上限 (1–50)"), limitField, limitStepper])
        limitRow.orientation = .horizontal
        limitRow.spacing = 8
        applyButton.target = self
        applyButton.action = #selector(applyTapped)
        let main = NSStackView(views: [row1, row2, row3, row4, row5, limitRow, applyButton])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 12
        main.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(main)
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            main.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            main.topAnchor.constraint(equalTo: view.topAnchor, constant: 20)
        ])
        enabledSwitch.state = (d.object(forKey: ZenzaiSettings.enabledKey) as? Bool ?? false) ? .on : .off
    }

    private func label(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.alignment = .right
        return t
    }

    private func rowStack(label title: String, control: NSView) -> NSStackView {
        let t = label(title)
        t.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let s = NSStackView(views: [t, control])
        s.orientation = .horizontal
        s.spacing = 12
        s.alignment = .top
        return s
    }

    @objc private func stepperChanged() {
        let v = max(1, min(50, Int(limitStepper.intValue)))
        limitField.stringValue = "\(v)"
    }

    @objc private func applyTapped() {
        saveToDefaults()
        NotificationCenter.default.post(name: .keynacoZenzaiSettingsDidChange, object: nil)
        applyButton.title = "保存しました"
        applyButton.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.applyButton.title = "保存"
            self?.applyButton.isEnabled = true
        }
    }

    /// 設定ウィンドウを閉じる前に未保存の UI を反映する（`SettingsWindowController` から呼ぶ）
    func saveToDefaults() {
        guard isViewLoaded else { return }
        let d = UserDefaults.standard
        d.set(enabledSwitch.state == .on, forKey: ZenzaiSettings.enabledKey)
        d.set(profileField.stringValue, forKey: ZenzaiSettings.profileKey)
        d.set(topicField.stringValue, forKey: ZenzaiSettings.topicKey)
        d.set(styleField.stringValue, forKey: ZenzaiSettings.styleKey)
        d.set(preferenceField.stringValue, forKey: ZenzaiSettings.preferenceKey)
        let fromField = Int(limitField.stringValue).map { max(1, min(50, $0)) }
        let n = fromField ?? max(1, min(50, Int(limitStepper.intValue)))
        limitField.stringValue = "\(n)"
        limitStepper.intValue = Int32(n)
        d.set(n, forKey: ZenzaiSettings.inferenceLimitKey)
    }
}
