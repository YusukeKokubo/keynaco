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
        let leftContext = handler.leftContext.azooKeyValue
        let converter = handler.azooKeyConverter
        azooKeyScheduler.schedule(
            generation: generation,
            reading: reading,
            leftSideContext: leftContext,
            converter: converter
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
        candidates: [String],
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
        if case .none = action { return }
        applyAsyncAzooKeyCandidateAction(action: action, adapter: adapter)
    }

    func applyAsyncAzooKeyCandidateAction(action: CandidateAction, adapter: IMKTextInputAdapter) {
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
    }
}
