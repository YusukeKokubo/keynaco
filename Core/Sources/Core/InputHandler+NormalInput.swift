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
        // NSEvent が機能キー（Forward Delete = U+F728、Home/End/PageUp 等）に使う私用領域の文字は
        // テキストではない。組成に混ぜると端末等で化けた字として確定される（macOS 更新後、Ctrl+D が
        // 修飾なしの Forward Delete として届くようになり顕在化）。組成中は読みの末尾にカーソルがあり
        // 前方に消すものがないので消費して無視し、組成外はホスト本来の動作に任せる。
        if chars.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) {
            return (state.isComposing, .none)
        }
        let base = baseCharacters ?? chars
        let isNonAscii = chars.unicodeScalars.contains(where: { $0.value >= 0x80 })

        if let r = handleZSequence(base: base, client: client) { return r }
        if let r = handleBracketChar(chars: chars, base: base, client: client) { return r }
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
        chars: String, base: String, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard let options = InputHandler.bracketOptions[chars] else { return nil }
        if !state.isComposing {
            candidateSession.beginBracketMode(options: options)
            return (true, .show(candidates: options, fixedEnd: 0))
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
        // `7gatu` → `7月` 等: 数字だけの ASCII 組成のあとローマ字を ASCII 語として連結しない。
        if state.composedHiragana.allSatisfy(\.isNumber),
           Self.isRomajiLetters(chars) {
            return nil
        }
        if wasExplicitlySelected { _ = doConfirmSelection(candidate: candidate, client: client) }
        state.composedHiragana += chars
        return (true, buildCandidateListForTrigger(.whileTyping))
    }

    private static func isRomajiLetters(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            ($0.value >= 0x61 && $0.value <= 0x7A) || $0.value == 0x2D
        }
    }

    private mutating func handleRomaji(
        base: String, wasExplicitlySelected: Bool, candidate: CandidateContext, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        if wasExplicitlySelected { _ = doConfirmSelection(candidate: candidate, client: client) }
        let needsRefresh = state.addRomaji(base)
        let candidateAction: CandidateAction = needsRefresh
            ? buildCandidateListForTrigger(.whileTyping)
            : .dismiss
        return (true, candidateAction)
    }
}
