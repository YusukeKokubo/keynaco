#if DEBUG

import Foundation
import KeynacoCore

extension DebugSocketServer {

    func cancelAzooKeyAsyncWork() {
        azooKeyScheduler.cancelPendingWork()
    }

    func warmRichCacheBeforeExplicitIfNeeded(keyCode: UInt16) {
        guard keyCode == KeyCode.space else { return }
        let state = handler.state
        guard !state.composedHiragana.isEmpty || !state.pendingRomaji.isEmpty else { return }
        let reading = state.composedHiraganaAfterAbsorbingPending()
        azooKeyScheduler.warmRichCacheForExplicit(
            reading: reading,
            leftSideContext: handler.leftContext.azooKeyValue,
            converter: handler.azooKeyConverter
        )
    }

    func scheduleSandboxAzooKeyIfNeeded(generation: Int, consumed: Bool) {
        guard consumed, let reading = handler.pendingAzooKeyReading else { return }
        let leftContext = handler.leftContext.azooKeyValue
        let converter = handler.azooKeyConverter
        let debounceNs = AzooKeyDebouncePolicy.nanoseconds(
            interKeyIntervalMs: azooKeyScheduler.lastInterKeyIntervalMs,
            pendingRomaji: handler.state.pendingRomaji,
            reading: reading
        )
        azooKeyScheduler.schedule(
            generation: generation,
            reading: reading,
            leftSideContext: leftContext,
            converter: converter,
            debounceNanoseconds: debounceNs
        ) { [self] candidates in
            applySandboxAzooKeyResult(
                generation: generation,
                reading: reading,
                candidates: candidates
            )
        }
    }

    private func applySandboxAzooKeyResult(
        generation: Int,
        reading: String,
        candidates: [AzooKeyCandidate]
    ) {
        let context = AsyncCandidateArrival.ApplyContext(
            candidateGeneration: azooKeyScheduler.candidateGeneration,
            arrivalGeneration: generation,
            reading: reading,
            composedHiragana: handler.state.composedHiragana,
            isExplicitlySelected: handler.candidateSession.isExplicitlySelected,
            isComposing: handler.state.isComposing
        )
        guard AsyncCandidateArrival.shouldApply(context) else { return }

        let action = handler.rebuildCandidateList(
            reading: reading,
            azooKeyCandidates: candidates,
            trigger: .whileTyping
        )
        if case .none = action { return }
        handler.applyCandidateAction(action, client: mockClient)
    }

    /// debounce タスク完了に加え、`.inject` 適用まで待つ（`pendingTask=nil` と `onComplete` の隙間対策）。
    private func isAzooPrefetchSettled() -> Bool {
        if azooKeyScheduler.hasPendingWork { return false }
        guard handler.deferAzooKeyWhileTyping else { return true }
        let hiragana = handler.state.composedHiragana
        guard hiragana.count >= 2, !hiragana.allSatisfy(\.isASCII) else { return true }
        return handler.pendingAzooKeyReading == nil
    }

    func handleWaitAzooKeyAsync(cmd: [String: Any]) async -> [String: Any] {
        let config = cmd["wait_azoo_key"]
        let timeoutMs: Int = {
            if let nested = config as? [String: Any], let t = nested["timeoutMs"] as? Int { return t }
            return cmd["timeoutMs"] as? Int ?? 3_000
        }()
        let timeoutNs = UInt64(max(0, timeoutMs)) * 1_000_000
        let step: UInt64 = 5_000_000
        var elapsed: UInt64 = 0
        var ok = false
        while elapsed < timeoutNs {
            if isAzooPrefetchSettled() {
                ok = true
                break
            }
            try? await Task.sleep(nanoseconds: step)
            elapsed += step
        }
        let state = makeResponse(inserted: [])
        return Self.finalize([
            "ok": ok,
            "pendingAzooKey": azooKeyScheduler.hasPendingWork,
            "pendingAzooKeyReading": handler.pendingAzooKeyReading as Any,
            "state": state,
        ], cmd: cmd)
    }
}

#endif
