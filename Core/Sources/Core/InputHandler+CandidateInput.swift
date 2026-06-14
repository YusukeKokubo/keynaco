import AppKit

// MARK: - 候補表示中のキー入力

extension InputHandler {

    @discardableResult
    mutating func doConfirmSelection(candidate: CandidateContext, client: TextInputClient) -> CandidateAction {
        guard state.isComposing else { return .none }
        let hasTrailingRomaji = !state.pendingRomaji.isEmpty || state.hiddenPendingN
        if !candidate.isExplicitlySelected, hasTrailingRomaji {
            commitComposition(client: client, candidate: .hidden, trigger: .enter)
            return .dismiss
        }
        let inputKey = state.finalizedText
        let normalizedInput = inputKey.allSatisfy({ $0.isASCII }) ? inputKey.lowercased() : inputKey
        // Enter キーによる確定: 視覚的に選択中の候補をそのまま確定する
        if let selected = candidate.selectedText {
            let isDateTime = Self.generateDateTimeCandidates(for: normalizedInput).contains(selected)
            let isNumber = Self.generateNumberCandidates(for: normalizedInput).contains(selected)
            if !isDateTime && !isNumber {
                db.recordPrefixes(reading: normalizedInput, output: selected)
            }
            let conv = azooKeyConverter; let r = inputKey; let t = selected
            Task.detached(priority: .utility) { conv.commit(reading: r, text: t) }
            commitText(text: selected, skipHistory: isDateTime || isNumber, client: client)
        } else {
            commitComposition(client: client, trigger: .enter)
        }
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
