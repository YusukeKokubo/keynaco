import Cocoa
import KeynacoCore
import InputMethodKit

extension InputController {

    /// LLM 用の文脈プレフィックス。合成ルールは `LeftContextResolver` が正本。
    func resolvedLLMDocumentContextPrefix(adapter: IMKTextInputAdapter) -> String {
        let loc = adapter.selectedRange().location
        guard loc != NSNotFound else {
            return LeftContextResolver.resolve(.init(
                sessionBuffer: handler.sessionTextBuffer,
                imkBefore: nil,
                cursorLocationAvailable: false
            ))
        }

        var imkBefore: String?
        if let cache = cachedSurroundingContext {
            if cache.location == loc, !cache.text.before.isEmpty {
                imkBefore = cache.text.before
            } else {
                cachedSurroundingContext = nil
            }
        }

        return LeftContextResolver.resolve(.init(
            sessionBuffer: handler.sessionTextBuffer,
            imkBefore: imkBefore,
            cursorLocationAvailable: true
        ))
    }

    /// 確定語の品詞を AzooKey 辞書で判定し、DB の pos を更新する。
    func schedulePOSClassification(output: String, reading: String) {
        guard HiraganaPreferredBuiltins.words[output] == nil else { return }
        guard DatabaseManager.shared.posForOutput(output) == nil else { return }
        let converter = handler.azooKeyConverter
        Task { @MainActor in
            guard let c = AzooKeyPOSClassifier.classify(
                output: output, reading: reading, converter: converter
            ) else { return }
            DatabaseManager.shared.updatePOS(output: output, pos: c.pos)
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
