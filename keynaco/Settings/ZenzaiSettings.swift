import Foundation
import KeynacoCore

enum ZenzaiSettings {
    static let enabledKey = "keynaco.zenzai.enabled"
    static let profileKey = "keynaco.zenzai.profile"
    static let topicKey = "keynaco.zenzai.topic"
    static let styleKey = "keynaco.zenzai.style"
    static let preferenceKey = "keynaco.zenzai.preference"
    static let inferenceLimitKey = "keynaco.zenzai.inferenceLimit"

    static func makeConverter() -> AzooKeyConverter {
        let d = UserDefaults.standard
        let enabled = d.object(forKey: enabledKey) as? Bool ?? false
        let profile = d.string(forKey: profileKey) ?? ""
        let manualTopic = d.string(forKey: topicKey) ?? ""
        let topic: String
        if manualTopic.isEmpty {
            let nouns = DatabaseManager.shared.recentProperNouns(limit: 5)
            topic = String(nouns.joined(separator: ",").prefix(25))
        } else {
            topic = manualTopic
        }
        let style = d.string(forKey: styleKey) ?? ""
        let preference = d.string(forKey: preferenceKey) ?? ""
        let limit = d.object(forKey: inferenceLimitKey) as? Int ?? 5
        return AzooKeyConverter(
            zenzaiEnabled: enabled,
            zenzaiProfile: profile,
            zenzaiTopic: topic,
            zenzaiStyle: style,
            zenzaiPreference: preference,
            zenzaiInferenceLimit: limit
        )
    }
}

extension Notification.Name {
    /// Zenzai 設定の「保存」または設定ウィンドウを閉じた後に投稿。`InputController` が `AzooKeyConverter` を再生成する。
    static let keynacoZenzaiSettingsDidChange = Notification.Name("keynaco.zenzai.settingsDidChange")
    /// ひらがな優先リストが変更されたときに投稿。`InputController` が `hiraganaPreferredSet` を再読み込みする。
    static let keynacoHiraganaPreferredDidChange = Notification.Name("keynaco.hiraganaPreferred.didChange")
}
