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

    /// 確定 `insertText` 後にカーソル前文を誤変換検出で検査（0.5 秒デバウンス）。
    func scheduleMisconversionCheck(adapter: IMKTextInputAdapter) {
        let prefix = adapter.surroundingText(maxLength: 200).prefix
        let recentWords = Array(handler.committedHistory.suffix(5))
        Self.misconversionChecker.check(surroundingPrefix: prefix, recentWords: recentWords)
    }

    /// `suggestSuccessors()` が立てた `successorLLMTrigger` に応じてオンデバイス LLM で後続語を補完する。
    func applySuccessorLLMScheduling(adapter: IMKTextInputAdapter) {
        let trigger = handler.successorLLMTrigger
        guard trigger != .none else { return }
        handler.successorLLMTrigger = .none

        let triggerContextOpt: [String]? = {
            switch trigger {
            case .pendingLowConfidence(let ctx), .particlesOnly(let ctx): return ctx
            case .none: return nil
            }
        }()
        let examples: [(prev: String, next: String)] = triggerContextOpt.flatMap { tc in
            tc.last.map { lw in
                handler.db.fetchBigramTop(prev: lw, limit: 5)
                    .filter { !InputHandler.particles.contains($0) }
                    .map { (prev: lw, next: $0) }
            }
        } ?? []

        switch trigger {
        case .none:
            break
        case .pendingLowConfidence(let triggerContext):
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
        case .particlesOnly(let triggerContext):
            let docPrefix = resolvedLLMDocumentContextPrefix(adapter: adapter)
            Self.successorLLM.fetch(
                context: triggerContext, documentContextPrefix: docPrefix, examples: examples
            ) { [weak self] words in
                guard let self else { return }
                guard Array(self.handler.committedHistory.suffix(3)) == triggerContext else { return }
                guard self.handler.isSuccessorMode,
                      self.candidateWindow.isVisible,
                      let base = self.handler.successorLLMBaseCandidates else { return }
                var seen = Set(base)
                seen.formUnion(self.handler.successorLLMSurfaceExtras)
                let extra = words.filter { !seen.contains($0) }
                guard !extra.isEmpty else { return }
                for w in extra where seen.insert(w).inserted {
                    self.handler.successorLLMSurfaceExtras.append(w)
                }
                var merged = base
                var tailSeen = Set(base)
                for w in self.handler.successorLLMSurfaceExtras where tailSeen.insert(w).inserted {
                    merged.append(w)
                }
                let rowCap = max(0, merged.count - 1)
                let initialRow = min(self.candidateWindow.selectedRow, rowCap)
                self.candidateWindow.show(
                    candidates: merged, historySectionEnd: 0, initialRow: initialRow,
                    predictionEnd: 0, fixedSectionEnd: 0, near: adapter.cursorRect()
                )
                if self.handler.isSuccessorMode, !merged.isEmpty,
                   let markedText = self.candidateWindow.selectedText(), !markedText.isEmpty {
                    adapter.setMarkedText(markedText, selectionRange: NSRange(location: markedText.count, length: 0))
                }
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
