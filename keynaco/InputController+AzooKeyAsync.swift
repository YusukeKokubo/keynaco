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
        let debounceNs = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: azooKeyScheduler.lastInterKeyIntervalMs,
            hasPendingRomaji: !handler.state.pendingRomaji.isEmpty
        ))
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
        guard azooKeyScheduler.candidateGeneration == generation else { return }
        guard handler.state.composedHiragana == reading else { return }
        guard !handler.candidateSession.isExplicitlySelected else { return }
        guard handler.state.isComposing else { return }

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
        let previousSelectedRow = handler.candidateSession.selectedRow
        let previousSelectedText = handler.candidateSession.selectedText

        handler.candidateSession.apply(action)

        if wasVisible,
           !handler.candidateSession.isExplicitlySelected,
           let text = previousSelectedText,
           previousSelectedRow < handler.candidateSession.candidates.count,
           handler.candidateSession.candidates[previousSelectedRow] == text {
            handler.candidateSession.selectedRow = previousSelectedRow
        }

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
