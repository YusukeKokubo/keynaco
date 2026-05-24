import Foundation
import KeynacoCore

enum ZenzaiSettings {
    static let enabledKey = "keynaco.zenzai.enabled"
    static let profileKey = "keynaco.zenzai.profile"
    static let inferenceLimitKey = "keynaco.zenzai.inferenceLimit"
    // topic/style/preference は zenz-v3.1-small では効果なし（POC260524 参照: plans/POC260524.md）

    static func makeConverter() -> AzooKeyConverter {
        let d = UserDefaults.standard
        let enabled = d.object(forKey: enabledKey) as? Bool ?? false
        let profile = d.string(forKey: profileKey) ?? ""
        let limit = d.object(forKey: inferenceLimitKey) as? Int ?? 5
        return AzooKeyConverter(zenzaiEnabled: enabled, zenzaiProfile: profile, zenzaiInferenceLimit: limit)
    }
}

extension Notification.Name {
    /// Zenzai 設定の「保存」または設定ウィンドウを閉じた後に投稿。`InputController` が `AzooKeyConverter` を再生成する。
    static let keynacoZenzaiSettingsDidChange = Notification.Name("keynaco.zenzai.settingsDidChange")
    /// ひらがな優先リストが変更されたときに投稿。`InputController` が `hiraganaPreferredSet` を再読み込みする。
    static let keynacoHiraganaPreferredDidChange = Notification.Name("keynaco.hiraganaPreferred.didChange")
}
