import AppKit

// MARK: - 候補表示中のキー入力

extension InputHandler {

    /// 候補ウィンドウ表示中の Enter 経路。確定本体は `commitComposition` に委ね、
    /// 候補状態マシンへ `.dismiss` を返す薄いラッパー。
    /// 末尾に未吸収ローマ字が残っていて explicit 選択でないとき（whileTyping 候補で Enter を押した場合）は、
    /// 視覚的選択を捨てて入力読みそのものを確定する。
    @discardableResult
    mutating func doConfirmSelection(candidate: CandidateContext, client: TextInputClient) -> CandidateAction {
        guard state.isComposing else { return .none }
        let hasTrailingRomaji = !state.pendingRomaji.isEmpty
        let effectiveCandidate: CandidateContext =
            (!candidate.isExplicitlySelected && hasTrailingRomaji) ? .hidden : candidate
        commitComposition(client: client, candidate: effectiveCandidate, trigger: .enter)
        return .dismiss
    }

    mutating func handleCandidateVisible(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        let isBackspace = keyCode == KeyCode.backspace || characters == "\u{08}"
        switch keyCode {
        case KeyCode.tab where modifiers.contains(.shift):
            return (true, .selectPrev)
        case KeyCode.space:
            // 候補表示中の Space は次候補（リストの再構築はしない）。未吸収ローマ字だけ先に組み込む。
            if !state.pendingRomaji.isEmpty {
                state.absorbPendingIntoComposed()
                return (true, buildCandidateList(trigger: .explicit))
            }
            if isAzooKeyPendingKanaPlaceholder(candidate) {
                return (true, buildCandidateList(trigger: .explicit))
            }
            return (true, .selectNext)
        case KeyCode.tab, KeyCode.downArrow:
            return (true, .selectNext)
        case KeyCode.upArrow:
            return (true, .selectPrev)
        case KeyCode.enter:
            return (true, doConfirmSelection(candidate: candidate, client: client))
        case KeyCode.escape:
            return doEscape(client: client)
        case KeyCode.rightArrow:
            commitComposition(client: client, trigger: .rightArrow)
            return (true, .dismiss)
        case KeyCode.backspace where modifiers.contains(.shift):
            let row = candidate.selectedRow
            if candidate.fixedEnd <= row && row < candidate.historyEnd { return (true, .deleteSelected) }
            return (true, .none)
        default:
            if isBackspace { return doBackspace(client: client) }
            return nil
        }
    }
}
