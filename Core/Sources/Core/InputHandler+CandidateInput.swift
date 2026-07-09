import AppKit

// MARK: - 候補表示中のキー入力

extension InputHandler {

    /// 候補ウィンドウ表示中の Enter 経路。確定本体は `commitComposition` に委ね、
    /// 候補状態マシンへ `.dismiss` を返す薄いラッパー。
    /// 候補が visible な状態で Enter を押したときは、候補選択操作（矢印/Space）の有無に
    /// 関わらず row 0（またはユーザーが選んだ行）を commit する（WYSIWYG）。
    /// pending romaji はここでは捨てられる — 保持したい場合は Escape → 再打鍵で対応する。
    @discardableResult
    mutating func doConfirmSelection(candidate: CandidateContext, client: TextInputClient) -> CandidateAction {
        guard state.isComposing else { return .none }
        commitComposition(client: client, candidate: candidate, trigger: .enter)
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
            // 打鍵中に自動表示された候補（ユーザー未操作）への Space は「次候補」ではなく
            // 「明示変換要求」として扱い、initialRow=0 から再開する。これをしないと AzooKey が
            // 自動表示した Z1 ひらがな候補を Space で素通りして Z2（カタカナ等）が確定する事故が起きる。
            if !candidate.isExplicitlySelected {
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
            if candidate.isHistoryDeletable(at: row) { return (true, .deleteSelected) }
            return (true, .none)
        default:
            if isBackspace { return doBackspace(client: client) }
            return nil
        }
    }
}
