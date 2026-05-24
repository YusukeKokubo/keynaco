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

    /// 確定語の品詞を LLM で非同期判定し、DB の pos を更新する。名詞なら noun_bigram を記録する。
    func schedulePOSClassification(output: String, reading: String, context: String? = nil) {
        let db = handler.db
        Self.posClassifier.enqueue(output: output, context: context) { [weak self] classifiedOutput, pos, posTag, posRetry in
            db.updatePOS(output: classifiedOutput, pos: pos, posTag: posTag, posRetry: posRetry)
            if pos == "noun" || pos.hasPrefix("proper_noun") {
                if let prev = self?.handler.lastConfirmedNounOutput {
                    db.recordNounBigram(prev: prev, input: reading, output: classifiedOutput)
                }
                self?.handler.lastConfirmedNounOutput = classifiedOutput
            }
        }
    }

    /// 未分類（pos IS NULL）または再試行待ち（pos_retry = 1）の履歴エントリを最大 50 件バックグラウンドで分類する（起動時に1回呼ぶ）。
    @MainActor
    static func performPOSBackfill() {
        let db = DatabaseManager.shared
        let outputs = db.fetchUnclassifiedHistory(limit: 50)
        for output in outputs {
            posClassifier.classify(output: output) { classifiedOutput, pos, posTag, posRetry in
                db.updatePOS(output: classifiedOutput, pos: pos, posTag: posTag, posRetry: posRetry)
            }
        }
    }

    /// IMK の `handle` / `activateServer` は nonisolated のため、通知だけ static で送る（MainActor の `self` を捕らない）。
    nonisolated static func postSuccessorPendingNotification(pending: Bool) {
        NotificationCenter.default.post(
            name: .keynacoSuccessorPendingChanged,
            object: nil,
            userInfo: ["pending": pending]
        )
    }
}
