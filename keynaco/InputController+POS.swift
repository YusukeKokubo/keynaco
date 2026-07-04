import Cocoa
import KeynacoCore
import InputMethodKit

extension InputController {

    /// 確定語の品詞を AzooKey 辞書で判定し、DB の pos を更新する。
    func schedulePOSClassification(output: String, reading: String) {
        Self.schedulePOSClassification(
            output: output,
            reading: reading,
            converter: handler.azooKeyConverter
        )
    }

    /// 設定画面のユーザー辞書登録など、任意の `AzooKeyConverting` から呼べる共有経路。
    static func schedulePOSClassification(
        output: String,
        reading: String,
        converter: AzooKeyConverting
    ) {
        guard HiraganaPreferredBuiltins.words[output] == nil else { return }
        if let pos = DatabaseManager.shared.posForOutput(output),
           pos.hasPrefix("other/") { return }
        if let pos = DatabaseManager.shared.posForOutput(output),
           pos != "other",
           DatabaseManager.shared.lcidForOutput(output) != nil { return }
        Task { @MainActor in
            guard let c = AzooKeyPOSClassifier.classify(
                output: output, reading: reading, converter: converter
            ) else { return }
            DatabaseManager.shared.upsertPOSClassification(
                output: output, reading: reading, pos: c.pos, lcid: c.lcid
            )
        }
    }

    /// 未分類（pos IS NULL）の履歴を AzooKey で一括再分類する（起動時にバックグラウンド実行）。
    nonisolated static func performPOSBackfill(limit: Int? = nil) {
        let result = AzooKeyPOSBackfill.run(limit: limit)
        if result.total > 0 {
            NSLog(
                "[keynaco] POS backfill: classified=%d skipped=%d total=%d remaining=%d",
                result.classified, result.skipped, result.total,
                DatabaseManager.shared.countUnclassifiedHistoryOutputs()
            )
        }
    }

}
