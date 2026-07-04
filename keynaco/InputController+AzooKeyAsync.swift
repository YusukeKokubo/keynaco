import Cocoa
import KeynacoCore
import InputMethodKit

extension InputController {

    func cancelAzooKeyAsyncWork() {
        azooKeyScheduler.cancelPendingWork()
    }

    /// Space 押下で `onKeyDown` が debounce を潰す前に rich キャッシュを温める。
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

    func scheduleAzooKeyReplacementIfNeeded(
        generation: Int,
        consumed: Bool,
        adapter: IMKTextInputAdapter
    ) {
        guard consumed, let reading = handler.pendingAzooKeyReading else { return }
        KeydownLatencySignpost.beginFetchComplete(generation: generation)
        let leftContext = handler.leftContext.azooKeyValue
        let converter = handler.azooKeyConverter
        let debounceNs = AzooKeyDebouncePolicy.nanoseconds(
            interKeyIntervalMs: azooKeyScheduler.lastInterKeyIntervalMs,
            pendingRomaji: handler.state.pendingRomaji,
            reading: reading
        )
        converter.latencyStats.recordDebounce(ms: Double(debounceNs) / 1_000_000)
        if let interKeyMs = azooKeyScheduler.lastInterKeyIntervalMs {
            converter.latencyStats.recordInterKey(ms: interKeyMs)
        }
        azooKeyScheduler.schedule(
            generation: generation,
            reading: reading,
            leftSideContext: leftContext,
            converter: converter,
            debounceNanoseconds: debounceNs
        ) { [weak self] candidates in
            guard let self else { return }
            self.applyAsyncAzooKeyResult(
                generation: generation,
                reading: reading,
                candidates: candidates,
                adapter: adapter
            )
        }
    }

    private func applyAsyncAzooKeyResult(
        generation: Int,
        reading: String,
        candidates: [AzooKeyCandidate],
        adapter: IMKTextInputAdapter
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
        if case .none = action {
            KeydownLatencySignpost.endFetchComplete(
                generation: generation,
                stats: handler.azooKeyConverter.latencyStats
            )
            return
        }
        applyAsyncAzooKeyCandidateAction(action: action, adapter: adapter, generation: generation)
    }

    func applyAsyncAzooKeyCandidateAction(
        action: CandidateAction,
        adapter: IMKTextInputAdapter,
        generation: Int
    ) {
        let wasVisible = handler.candidateSession.isVisible
        let preservation = AsyncCandidateArrival.rowPreservationSnapshot(from: handler.candidateSession)
        AsyncCandidateArrival.applyCandidateAction(
            session: &handler.candidateSession,
            action: action,
            preservation: preservation
        )

        applyCandidateWindowEffects(
            action: action,
            adapter: adapter,
            preferInPlaceRefresh: wasVisible
        )
        KeydownLatencySignpost.endFetchComplete(
            generation: generation,
            stats: handler.azooKeyConverter.latencyStats
        )
    }
}
