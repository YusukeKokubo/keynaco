import AppKit

// MARK: - handle() ディスパッチ

extension InputHandler {

    public mutating func handle(
        keyCode: UInt16,
        characters: String?,
        baseCharacters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        clearPendingAzooKeyReading()
        let isBackspace = keyCode == KeyCode.backspace || characters == "\u{08}"
        clearLastConfirmedContextUnlessBackspace(isBackspace: isBackspace)

        lastKeyDownDidPenalize = false
        if !state.isComposing {
            sessionTracker.reset()
        } else {
            sessionTracker.track(keyCode: keyCode)
        }

        let route = KeyDispatch.route(KeyDispatchInput(
            keyCode: keyCode,
            isBackspace: isBackspace,
            isAsciiMode: Self.isAsciiMode,
            isBracketMode: isBracketMode,
            candidateVisible: candidate.isVisible,
            isComposing: state.isComposing,
            ignoreNextModeSwitch: ignoreNextModeSwitch
        ))

        let wasExplicitlySelected = candidate.panelInteraction == .explicit

        switch route {
        case .bracketMode:
            return handleBracketModeKey(
                keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                modifiers: modifiers, candidate: candidate, client: client)

        case .functionKey:
            return handleFunctionKeyIfNeeded(keyCode: keyCode, client: client)

        case .modeSwitch(let suppressEcho):
            return handleModeSwitchKey(keyCode: keyCode, suppressEcho: suppressEcho, client: client)

        case .asciiMode:
            ignoreNextModeSwitch = false
            return handleAsciiModeKey(
                keyCode: keyCode, characters: characters, modifiers: modifiers, client: client)

        case .candidateVisible:
            ignoreNextModeSwitch = false
            if let r = handleCandidateVisible(
                keyCode: keyCode, characters: characters,
                modifiers: modifiers, candidate: candidate, client: client) { return r }
            return handleNormalInput(
                keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                modifiers: modifiers, wasExplicitlySelected: wasExplicitlySelected,
                candidate: candidate, client: client)

        case .composeOnly(let key):
            ignoreNextModeSwitch = false
            return handleComposeOnlyKey(key, client: client)

        case .normalInput:
            ignoreNextModeSwitch = false
            return handleNormalInput(
                keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                modifiers: modifiers, wasExplicitlySelected: wasExplicitlySelected,
                candidate: candidate, client: client)
        }
    }

    private mutating func clearLastConfirmedContextUnlessBackspace(isBackspace: Bool) {
        if !isBackspace { lastConfirmedContext = nil }
    }

    private mutating func resetContextOnEnter() {
        committedHistory.removeAll()
        sessionTextBuffer = ""
        leftContextIMKCache = .invalidated
    }

    private mutating func handleFunctionKeyIfNeeded(
        keyCode: UInt16, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        let consumed = handleFunctionKey(keyCode: keyCode, client: client)
        return (consumed, consumed ? .dismiss : .none)
    }

    private mutating func handleModeSwitchKey(
        keyCode: UInt16,
        suppressEcho: Bool,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        if suppressEcho {
            ignoreNextModeSwitch = false
            return (true, .none)
        }
        if keyCode == KeyCode.eisu {
            if state.isComposing { commitComposition(client: client, trigger: .modeSwitch) }
            Self.isAsciiMode = true
        } else {
            Self.isAsciiMode = false
        }
        return (true, .none)
    }

    private mutating func handleAsciiModeKey(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        if keyCode == KeyCode.escape { Self.isAsciiMode = false; return (true, .none) }
        if keyCode == KeyCode.enter {
            resetContextOnEnter()
            return (false, .none)
        }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return (false, .none) }
        guard let chars = characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return (false, .none) }
        client.insertText(chars)
        return (true, .none)
    }

    private mutating func handleComposeOnlyKey(
        _ key: ComposeOnlyKey,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        switch key {
        case .enter:
            guard state.isComposing else {
                resetContextOnEnter()
                return (false, .none)
            }
            commitComposition(client: client, trigger: .enter)
            return (true, .dismiss)
        case .escape:
            return doEscape(client: client)
        case .backspace:
            return doBackspace(client: client)
        }
    }
}
