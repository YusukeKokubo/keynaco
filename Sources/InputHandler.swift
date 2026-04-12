import AppKit

/// 候補ウィンドウに対する操作指示
enum CandidateAction {
    case none
    case show(candidates: [String], historyEnd: Int)
    case dismiss
    case selectNext
    case selectPrev
}

/// 候補ウィンドウの現在状態スナップショット（読み取り専用）
struct CandidateContext {
    var isVisible: Bool
    var selectedRow: Int
    var selectedText: String?

    static let hidden = CandidateContext(isVisible: false, selectedRow: 0, selectedText: nil)
}

/// 入力処理の本体。IMK・UI に依存しない純粋なロジック。
struct InputHandler {

    var state = CompositionState()
    var ignoreNextModeSwitch = false
    let db: DatabaseManager

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    // MARK: - 公開インターフェース

    mutating func handle(
        keyCode: UInt16,
        characters: String?,
        baseCharacters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {

        let wasExplicitlySelected = candidate.isVisible && candidate.selectedRow > 0

        // 英数キー (102) / かなキー (104)
        if keyCode == 102 || keyCode == 104 {
            if ignoreNextModeSwitch {
                ignoreNextModeSwitch = false
                return (true, .none)
            }
            if keyCode == 102 {
                if !state.composingText.isEmpty { commitComposition(client: client) }
                state.isAsciiMode = true
            } else {
                state.isAsciiMode = false
            }
            return (true, .none)
        }
        ignoreNextModeSwitch = false

        // 英字モード
        if state.isAsciiMode {
            if keyCode == 53 { state.isAsciiMode = false; return (true, .none) }
            guard modifiers.intersection([.command, .control, .option]).isEmpty else { return (false, .none) }
            guard let chars = characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return (false, .none) }
            client.insertText(chars)
            return (true, .none)
        }

        let isBackspace = keyCode == 51 || characters == "\u{08}"

        // 候補ウィンドウ表示中
        if candidate.isVisible {
            switch keyCode {
            case 48 where modifiers.contains(.shift):  // Shift+Tab
                return (true, .selectPrev)
            case 49:   // Space → 次の候補
                return (true, .selectNext)
            case 48, 125:  // Tab, ↓
                return (true, .selectNext)
            case 126:  // ↑
                return (true, .selectPrev)
            case 36:   // Return
                let action = doConfirmSelection(candidate: candidate, client: client)
                return (true, action)
            case 53:   // Escape
                return doEscape(client: client)
            default:
                if isBackspace { return doBackspace(client: client) }
            }
        } else {
            switch keyCode {
            case 36:   // Return
                guard !state.composingText.isEmpty else { return (false, .none) }
                commitComposition(client: client)
                return (true, .none)
            case 53:   // Escape
                return doEscape(client: client)
            default:
                if isBackspace { return doBackspace(client: client) }
            }
        }

        // スペースキー（候補なし時）
        if keyCode == 49 {
            if !state.composedHiragana.isEmpty {
                let action = doRefreshCandidates()
                applyMarkedText(candidateText: nil, client: client)
                return (true, action)
            }
            return (false, .none)
        }

        // 矢印キー等の特殊キー
        if keyCode >= 123 && keyCode <= 126 { return (false, .none) }

        // 修飾キー付きはスルー
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return (false, .none) }

        // 印字可能文字のみ
        guard let chars = characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return (false, .none) }
        let base = baseCharacters ?? chars

        // 句読点・記号
        if let mapped = RomajiConverter.punctuationMap[chars] {
            if wasExplicitlySelected {
                _ = doConfirmSelection(candidate: candidate, client: client)
            } else if !state.composingText.isEmpty {
                commitTopCandidate(client: client)
            }
            client.insertText(mapped)
            return (true, .dismiss)
        }

        // Shift → 英字を直接挿入
        if modifiers.contains(.shift) {
            if wasExplicitlySelected {
                _ = doConfirmSelection(candidate: candidate, client: client)
            } else if !state.composingText.isEmpty {
                commitComposition(client: client)
            }
            client.insertText(chars)
            return (true, .dismiss)
        }

        if wasExplicitlySelected {
            _ = doConfirmSelection(candidate: candidate, client: client)
        }
        let needsRefresh = state.addRomaji(base)
        let candidateAction: CandidateAction = needsRefresh ? doRefreshCandidates() : .dismiss
        applyMarkedText(candidateText: nil, client: client)
        return (true, candidateAction)
    }

    /// deactivateServer / commitComposition から呼ばれる未確定テキストの強制確定
    mutating func commitComposition(client: TextInputClient) {
        guard !state.composingText.isEmpty else { return }
        let finalText = state.finalizedText
        db.record(input: finalText, output: finalText)
        doCommit(text: finalText, client: client)
    }

    // MARK: - プライベートヘルパー

    @discardableResult
    private mutating func doConfirmSelection(candidate: CandidateContext, client: TextInputClient) -> CandidateAction {
        guard !state.composingText.isEmpty else { return .none }
        let inputKey = state.finalizedText
        if let selected = candidate.selectedText {
            db.record(input: inputKey, output: selected)
            doCommit(text: selected, client: client)
        } else {
            commitComposition(client: client)
        }
        return .dismiss
    }

    private mutating func doCommit(text: String, client: TextInputClient) {
        client.insertText(text)
        state = CompositionState()
    }

    private mutating func doRefreshCandidates() -> CandidateAction {
        let result = db.fetchCandidates(prefix: state.composedHiragana)
        var candidates = result.candidates
        let hadHiragana = candidates.contains(state.composedHiragana)
        candidates.removeAll { $0 == state.composedHiragana }
        candidates.insert(state.composedHiragana, at: 0)
        let historyEnd = 1 + (hadHiragana ? result.historyCount - 1 : result.historyCount)
        guard !candidates.isEmpty else { return .dismiss }
        return .show(candidates: candidates, historyEnd: historyEnd)
    }

    private func applyMarkedText(candidateText: String?, client: TextInputClient) {
        let text: String
        if let selected = candidateText {
            text = selected + state.pendingRomaji
        } else {
            text = state.composingText
        }
        client.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0))
    }

    private mutating func doBackspace(client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction) {
        let (handled, needsRefresh) = state.backspace()
        guard handled else { return (false, .none) }
        let action: CandidateAction = needsRefresh ? doRefreshCandidates() : .dismiss
        applyMarkedText(candidateText: nil, client: client)
        return (true, action)
    }

    private mutating func doEscape(client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction) {
        guard state.reset() else { return (false, .none) }
        applyMarkedText(candidateText: nil, client: client)
        return (true, .dismiss)
    }

    private mutating func commitTopCandidate(client: TextInputClient) {
        let inputKey = state.finalizedText
        if !state.composedHiragana.isEmpty {
            let result = db.fetchCandidates(prefix: state.composedHiragana)
            let top = result.candidates.first ?? inputKey
            db.record(input: inputKey, output: top)
            doCommit(text: top, client: client)
        } else {
            commitComposition(client: client)
        }
    }
}
