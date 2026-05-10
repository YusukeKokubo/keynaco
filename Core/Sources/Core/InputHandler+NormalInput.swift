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
                let action = enterSegmentMode()
                if state.isSegmentMode { applySegmentMarkedText(client: client) }
                else { applyMarkedText(candidateText: nil, client: client) }
                return (true, action)
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
        if let r = handlePunctuation(base: base, modifiers: modifiers, client: client) { return r }
        if let r = handleBracketChar(chars: chars, client: client) { return r }
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
        let action = buildCandidateList()
        applyMarkedText(candidateText: nil, client: client)
        return (true, action)
    }

    private mutating func handleZSequence(base: String, client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard state.pendingRomaji == "z", let special = Self.zCharMap[base] else { return nil }
        return commitZSequence(special: special, client: client)
    }

    private mutating func handlePunctuation(
        base: String, modifiers: NSEvent.ModifierFlags, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard let mappedPunct = Self.punctuationMap[base], !modifiers.contains(.shift) else { return nil }
        if state.composingText.isEmpty {
            pushCommitted(mappedPunct)
            client.insertText(mappedPunct)
            return (true, .dismiss)
        }
        flushPendingRomaji()
        state.composedHiragana += mappedPunct
        let action = buildCandidateList()
        applyMarkedText(candidateText: nil, client: client)
        return (true, action)
    }

    private mutating func handleBracketChar(
        chars: String, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard let options = InputHandler.bracketOptions[chars] else { return nil }
        if state.composingText.isEmpty {
            bracketCandidates = options
            client.setMarkedText(options[0], selectionRange: NSRange(location: options[0].count, length: 0))
            return (true, .show(candidates: options, historyEnd: 0, initialRow: 0, predictionEnd: 0, fixedEnd: 0))
        }
        flushPendingRomaji()
        state.composedHiragana += options[0]
        let action = buildCandidateList()
        applyMarkedText(candidateText: nil, client: client)
        return (true, action)
    }

    private mutating func handleShiftChar(
        chars: String, isNonAscii: Bool, modifiers: NSEvent.ModifierFlags,
        wasExplicitlySelected: Bool, candidate: CandidateContext, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard modifiers.contains(.shift) && !isNonAscii else { return nil }
        if wasExplicitlySelected { _ = doConfirmSelection(candidate: candidate, client: client) }
        else { flushPendingRomaji() }
        state.composedHiragana += chars
        let action = buildCandidateList(autoShow: true)
        applyMarkedText(candidateText: nil, client: client)
        return (true, action)
    }

    private mutating func handleNonAsciiChar(
        chars: String, isNonAscii: Bool, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard isNonAscii else { return nil }
        if state.composingText.isEmpty {
            pushCommitted(chars)
            client.insertText(chars)
        } else {
            flushPendingRomaji()
            state.composedHiragana += chars
            applyMarkedText(candidateText: nil, client: client)
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
        let action = buildCandidateList(autoShow: true)
        applyMarkedText(candidateText: nil, client: client)
        return (true, action)
    }

    private mutating func handleRomaji(
        base: String, wasExplicitlySelected: Bool, candidate: CandidateContext, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        if wasExplicitlySelected { _ = doConfirmSelection(candidate: candidate, client: client) }
        let needsRefresh = state.addRomaji(base)
        let hasBigramContext = lastCommittedOutput != nil && !state.composedHiragana.isEmpty
        let pending = state.pendingRomaji
        let hasPendingPreview = lastCommittedOutput != nil
            && state.composedHiragana.isEmpty
            && pending.count == 1
            && pending != "n"
            && InputHandler.romajiToInitialKana[pending] != nil

        let candidateAction: CandidateAction
        if needsRefresh || hasBigramContext {
            candidateAction = buildCandidateList(autoShow: true)
        } else if hasPendingPreview {
            candidateAction = buildPendingCandidateList(pendingChar: pending, client: client)
        } else {
            candidateAction = .dismiss
        }
        if !isSuccessorMode { applyMarkedText(candidateText: nil, client: client) }
        return (true, candidateAction)
    }
}
