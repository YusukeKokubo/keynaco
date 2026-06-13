import AppKit

// MARK: - 通常入力（ローマ字・記号・括弧・z シーケンス）

public extension InputHandler {

    // handleNormalInput は入力種別ごとのプライベートハンドラへ振り分けるディスパッチテーブル。
    // 各ハンドラは nil（自分の担当外）または (consumed, action) を返す。
    mutating func handleNormalInput(
        keyCode: UInt16,
        characters: String?,
        baseCharacters: String?,
        modifiers: NSEvent.ModifierFlags,
        wasExplicitlySelected: Bool,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        if keyCode == KeyCode.space {
            if !state.composedHiragana.isEmpty {
                state.absorbPendingIntoComposed()
                return (true, buildCandidateList(trigger: .explicit))
            }
            // composed のみ空で pending ローマ字だけあるとき Space をホストへ漏らすと未確定が消えることがあるため消費する
            if !state.pendingRomaji.isEmpty {
                return (true, .none)
            }
            return (false, .none)
        }

        // z + 矢印キー（矢印フィルタより前に処理）
        if state.pendingRomaji == "z", let special = Self.zArrowMap[keyCode] {
            return commitZSequence(special: special, client: client)
        }

        if keyCode >= KeyCode.leftArrow && keyCode <= KeyCode.upArrow { return (false, .none) }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return (false, .none) }
        guard let chars = characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return (false, .none) }
        let base = baseCharacters ?? chars
        let isNonAscii = chars.unicodeScalars.contains(where: { $0.value >= 0x80 })

        if let r = handleZSequence(base: base, client: client) { return r }
        if let r = handleBracketChar(chars: chars, base: base, modifiers: modifiers, client: client) { return r }
        if let r = handleShiftChar(chars: chars, isNonAscii: isNonAscii, modifiers: modifiers,
                                    wasExplicitlySelected: wasExplicitlySelected,
                                    candidate: candidate, client: client) { return r }
        if let r = handleNonAsciiChar(chars: chars, isNonAscii: isNonAscii, client: client) { return r }
        if let r = handleAsciiWord(chars: chars, wasExplicitlySelected: wasExplicitlySelected,
                                    candidate: candidate, client: client) { return r }
        return handleRomaji(base: base, wasExplicitlySelected: wasExplicitlySelected,
                             candidate: candidate, client: client)
    }

    // MARK: - Private input handlers

    private mutating func flushPendingRomaji() {
        state.absorbPendingIntoComposed()
    }

    private mutating func commitZSequence(special: String, client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction) {
        state.pendingRomaji = ""
        if state.composedHiragana.isEmpty {
            client.insertText(special)
            return (true, .dismiss)
        }
        state.composedHiragana += special
        return (true, buildCandidateList())
    }

    private mutating func handleZSequence(base: String, client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard state.pendingRomaji == "z", let special = Self.zCharMap[base] else { return nil }
        return commitZSequence(special: special, client: client)
    }

    private mutating func handleBracketChar(
        chars: String, base: String, modifiers: NSEvent.ModifierFlags, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard let options = InputHandler.bracketOptions[chars] else { return nil }
        if !state.isComposing {
            bracketCandidates = options
            return (true, .show(candidates: options, historyEnd: 0, initialRow: 0, fixedEnd: 0))
        }
        flushPendingRomaji()
        state.composedHiragana += options[0]
        return (true, buildCandidateList())
    }

    private mutating func handleShiftChar(
        chars: String, isNonAscii: Bool, modifiers: NSEvent.ModifierFlags,
        wasExplicitlySelected: Bool, candidate: CandidateContext, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard modifiers.contains(.shift) && !isNonAscii else { return nil }
        if wasExplicitlySelected { _ = doConfirmSelection(candidate: candidate, client: client) }
        else { flushPendingRomaji() }
        state.composedHiragana += chars
        return (true, buildCandidateListForTrigger(.whileTyping))
    }

    private mutating func handleNonAsciiChar(
        chars: String, isNonAscii: Bool, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard isNonAscii else { return nil }
        if !state.isComposing {
            pushCommitted(chars)
            client.insertText(chars)
        } else {
            flushPendingRomaji()
            state.composedHiragana += chars
        }
        return (true, .dismiss)
    }

    private mutating func handleAsciiWord(
        chars: String, wasExplicitlySelected: Bool, candidate: CandidateContext, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard !state.composedHiragana.isEmpty && state.pendingRomaji.isEmpty
              && state.composedHiragana.allSatisfy({ $0.isASCII }) else { return nil }
        if wasExplicitlySelected { _ = doConfirmSelection(candidate: candidate, client: client) }
        state.composedHiragana += chars
        return (true, buildCandidateListForTrigger(.whileTyping))
    }

    private static let vowelKeys: Set<Character> = ["a", "i", "u", "e", "o", "n"]

    private mutating func handleRomaji(
        base: String, wasExplicitlySelected: Bool, candidate: CandidateContext, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        if wasExplicitlySelected { _ = doConfirmSelection(candidate: candidate, client: client) }
        let needsRefresh = state.addRomaji(base)
        let isVowelKey = base.count == 1 && Self.vowelKeys.contains(base.lowercased().first!)
        let candidateAction: CandidateAction
        if needsRefresh {
            candidateAction = isVowelKey
                ? buildCandidateListForTrigger(.whileTyping)
                : .none
        } else {
            candidateAction = .dismiss
        }
        return (true, candidateAction)
    }
}
