import Cocoa
import KeynacoCore
import InputMethodKit

extension InputController {

    /// LLM 用の文脈プレフィックス。IMK の `before`（キャッシュ・location 一致時）が非空なら、`committedHistory.suffix(5)` が空でないときは先頭にその全量を付けたうえで `before` を続ける（`before` は最大 300 字に切り詰めた後、結合総長が 400 字を超えないようカーソル近傍の末尾側を採用）。`historyJoined` は切り捨てない。`before` が空またはキャッシュ不一致時は `committedHistory.suffix(5)` のみ。
    func resolvedLLMDocumentContextPrefix(adapter: IMKTextInputAdapter) -> String {
        let historyJoined = handler.committedHistory.suffix(5).joined()
        let loc = adapter.selectedRange().location
        guard loc != NSNotFound else { return historyJoined }

        if let cache = cachedSurroundingContext, cache.location == loc, !cache.text.before.isEmpty {
            let rawBefore = cache.text.before
            let beforeTruncated =
                rawBefore.count > 300 ? String(rawBefore.suffix(300)) : rawBefore
            if !historyJoined.isEmpty {
                let maxBefore = max(0, 400 - historyJoined.count)
                let trimmedBefore =
                    beforeTruncated.count > maxBefore
                    ? String(beforeTruncated.suffix(maxBefore))
                    : beforeTruncated
                return historyJoined + trimmedBefore
            }
            return beforeTruncated
        }

        if cachedSurroundingContext != nil {
            cachedSurroundingContext = nil
        }
        return historyJoined
    }

    /// 確定語の品詞を LLM で非同期判定し、DB の pos を更新する。
    func schedulePOSClassification(output: String, reading: String, context: String? = nil) {
        guard HiraganaPreferredBuiltins.stopWords[output] == nil else { return }
        Self.posClassifier.enqueue(output: output, context: context) { classifiedOutput, pos, posTag, posRetry, lemma in
            DatabaseManager.shared.updatePOS(
                output: classifiedOutput, pos: pos, posTag: posTag, lemma: lemma, posRetry: posRetry
            )
        }
    }

    /// 未分類（pos IS NULL）または再試行待ち（pos_retry = 1）の履歴エントリを最大 50 件バックグラウンドで分類する（起動時に1回呼ぶ）。
    @MainActor
    static func performPOSBackfill() {
        let db = DatabaseManager.shared
        let outputs = db.fetchUnclassifiedHistory(limit: 50)
        for output in outputs {
            posClassifier.classify(output: output) { classifiedOutput, pos, posTag, posRetry, lemma in
                db.updatePOS(output: classifiedOutput, pos: pos, posTag: posTag, lemma: lemma, posRetry: posRetry)
            }
        }
    }

}
