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
    func schedulePOSClassification(output: String, reading: String) {
        let db = handler.db
        let prevNoun = handler.lastConfirmedNounOutput
        Self.posClassifier.classify(output: output) { [weak self] classifiedOutput, pos in
            db.updatePOS(output: classifiedOutput, pos: pos)
            if pos == "noun" {
                if let prev = prevNoun {
                    db.recordNounBigram(prev: prev, input: reading, output: classifiedOutput)
                }
                self?.handler.lastConfirmedNounOutput = classifiedOutput
            }
        }
    }

    /// 未分類（pos = NULL）の履歴エントリを最大 50 件バックグラウンドで分類する（起動時に1回呼ぶ）。
    @MainActor
    static func performPOSBackfill() {
        let db = DatabaseManager.shared
        let outputs = db.fetchUnclassifiedHistory(limit: 50)
        for output in outputs {
            posClassifier.classify(output: output) { classifiedOutput, pos in
                db.updatePOS(output: classifiedOutput, pos: pos)
            }
        }
    }

    /// 確定 `insertText` 後にカーソル前文を誤変換検出で検査（0.5 秒デバウンス）。
    func scheduleMisconversionCheck(adapter: IMKTextInputAdapter) {
        let prefix = adapter.surroundingText(maxLength: 200).prefix
        let recentWords = Array(handler.committedHistory.suffix(5))
        Self.misconversionChecker.check(surroundingPrefix: prefix, recentWords: recentWords)
    }

    /// `suggestSuccessors()` が立てた `successorLLMContext` に応じてオンデバイス LLM で後続語を補完する。
    func applySuccessorLLMScheduling(adapter: IMKTextInputAdapter) {
        guard let triggerContext = handler.successorLLMContext else { return }
        handler.successorLLMContext = nil

        let examples: [(prev: String, next: String)] = triggerContext.last.map { lw in
            let fromNoun = handler.lastConfirmedNounOutput.map {
                handler.db.fetchNounBigramTop(prev: $0, limit: 5)
            } ?? []
            let fromBigram = handler.db.fetchBigramTop(prev: lw, limit: 5)
            return InputHandler.merged(fromNoun, fromBigram)
                .filter { !InputHandler.particles.contains($0) }
                .map { (prev: lw, next: $0) }
        } ?? []

        let docPrefix = resolvedLLMDocumentContextPrefix(adapter: adapter)
        Self.successorLLM.fetch(
            context: triggerContext, documentContextPrefix: docPrefix, examples: examples
        ) { [weak self] words in
            guard let self else { return }
            guard Array(self.handler.committedHistory.suffix(3)) == triggerContext else { return }
            guard self.handler.isSuccessorMode else { return }
            var seen = Set(self.handler.pendingSuccessorCandidates)
            seen.formUnion(self.handler.successorLLMSurfaceExtras)
            let extra = words.filter { !seen.contains($0) }
            guard !extra.isEmpty else { return }
            self.handler.successorLLMSurfaceExtras.append(contentsOf: extra)
            if !self.handler.pendingSuccessorCandidates.isEmpty {
                Self.postSuccessorPendingNotification(pending: true)
            }
        }
    }

    /// `enterSegmentMode()` が立てた `segmentLLMTrigger` に応じ、プリフェッチ済みの LLM 変換があれば同期的に適用する（未完了時は AzooKey のまま）。
    func applySegmentLLMScheduling(adapter: IMKTextInputAdapter) {
        let trigger = handler.segmentLLMTrigger
        guard case .start(let hiragana) = trigger else { return }
        handler.segmentLLMTrigger = .none
        guard let trimmed = Self.segmentLLM.takePrefetchIfMatching(hiragana: hiragana) else { return }
        guard !trimmed.isEmpty,
              let segState = handler.state.segmentState,
              segState.segments.map(\.reading).joined() == hiragana else { return }
        handler.applyLLMSegmentResult(text: trimmed)
        guard let updated = handler.state.segmentState,
              updated.llmWholeText != nil,
              !updated.segments.isEmpty else { return }
        let action = handler.makeCandidateActionForFocusedSegment()
        if case .show(let cands, let historyEnd, let initialRow, let predictionEnd, let fixedEnd) = action {
            candidateWindow.show(
                candidates: cands, historySectionEnd: historyEnd, initialRow: initialRow,
                predictionEnd: predictionEnd, fixedSectionEnd: fixedEnd, near: adapter.cursorRect()
            )
            handler.applySegmentMarkedText(client: adapter)
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
