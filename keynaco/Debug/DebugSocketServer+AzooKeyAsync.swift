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
        let debounceNs = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: azooKeyScheduler.lastInterKeyIntervalMs,
            hasPendingRomaji: !handler.state.pendingRomaji.isEmpty
        ))
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
        guard azooKeyScheduler.candidateGeneration == generation else { return }
        guard handler.state.composedHiragana == reading else { return }
        guard !handler.candidateSession.isExplicitlySelected else { return }
        guard handler.state.isComposing else { return }

        let action = handler.rebuildCandidateList(
            reading: reading,
            azooKeyCandidates: candidates,
            trigger: .whileTyping
        )
        if case .none = action { return }
        handler.candidateSession.apply(action)
    }

    func handleWaitAzooKeyAsync(cmd: [String: Any]) async -> [String: Any] {
        let config = cmd["wait_azoo_key"]
        let timeoutMs: Int = {
            if let nested = config as? [String: Any], let t = nested["timeoutMs"] as? Int { return t }
            return cmd["timeoutMs"] as? Int ?? 2_000
        }()
        let ok = await azooKeyScheduler.waitUntilIdle(
            timeoutNanoseconds: UInt64(max(0, timeoutMs)) * 1_000_000
        )
        let state = makeResponse(inserted: [])
        return Self.finalize([
            "ok": ok,
            "pendingAzooKey": azooKeyScheduler.hasPendingWork,
            "state": state,
        ], cmd: cmd)
    }
}

#endif
