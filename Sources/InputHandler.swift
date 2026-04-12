import AppKit

/// 候補ウィンドウに対する操作指示
enum CandidateAction {
    case none
    case show(candidates: [String], historyEnd: Int, initialRow: Int)
    case dismiss
    case selectNext
    case selectPrev
}

/// 候補ウィンドウの現在状態スナップショット（読み取り専用）
struct CandidateContext {
    var isVisible: Bool
    var selectedRow: Int
    var selectedText: String?
    /// ユーザーが ↑↓ で明示的に候補を動かしたか（初期表示のまま = false）
    var isExplicitlySelected: Bool = false

    static let hidden = CandidateContext(isVisible: false, selectedRow: 0, selectedText: nil)
}

private enum KeyCode {
    static let eisu:      UInt16 = 102
    static let kana:      UInt16 = 104
    static let backspace: UInt16 = 51
    static let space:     UInt16 = 49
    static let enter:     UInt16 = 36
    static let escape:    UInt16 = 53
    static let tab:       UInt16 = 48
    static let downArrow: UInt16 = 125
    static let upArrow:   UInt16 = 126
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
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

        let wasExplicitlySelected = candidate.isVisible && candidate.isExplicitlySelected

        // 英数キー / かなキー
        if keyCode == KeyCode.eisu || keyCode == KeyCode.kana {
            if ignoreNextModeSwitch {
                ignoreNextModeSwitch = false
                return (true, .none)
            }
            if keyCode == KeyCode.eisu {
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
            if keyCode == KeyCode.escape { state.isAsciiMode = false; return (true, .none) }
            guard modifiers.intersection([.command, .control, .option]).isEmpty else { return (false, .none) }
            guard let chars = characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return (false, .none) }
            client.insertText(chars)
            return (true, .none)
        }

        let isBackspace = keyCode == KeyCode.backspace || characters == "\u{08}"

        // 候補ウィンドウ表示中
        if candidate.isVisible {
            switch keyCode {
            case KeyCode.tab where modifiers.contains(.shift):  // Shift+Tab
                return (true, .selectPrev)
            case KeyCode.space:   // Space → 次の候補
                return (true, .selectNext)
            case KeyCode.tab, KeyCode.downArrow:  // Tab, ↓
                return (true, .selectNext)
            case KeyCode.upArrow:  // ↑
                return (true, .selectPrev)
            case KeyCode.enter:   // Return
                let action = doConfirmSelection(candidate: candidate, client: client)
                return (true, action)
            case KeyCode.escape:  // Escape
                return doEscape(client: client)
            default:
                if isBackspace { return doBackspace(client: client) }
            }
        } else {
            switch keyCode {
            case KeyCode.enter:   // Return
                guard !state.composingText.isEmpty else { return (false, .none) }
                commitComposition(client: client)
                return (true, .none)
            case KeyCode.escape:  // Escape
                return doEscape(client: client)
            default:
                if isBackspace { return doBackspace(client: client) }
            }
        }

        // スペースキー（候補なし時）
        if keyCode == KeyCode.space {
            if !state.composedHiragana.isEmpty {
                let action = doRefreshCandidates()
                applyMarkedText(candidateText: nil, client: client)
                return (true, action)
            }
            return (false, .none)
        }

        // 矢印キー等の特殊キー
        if keyCode >= KeyCode.leftArrow && keyCode <= KeyCode.upArrow { return (false, .none) }

        // 修飾キー付きはスルー
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return (false, .none) }

        // 印字可能文字のみ
        guard let chars = characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return (false, .none) }
        let base = baseCharacters ?? chars

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

    /// deactivateServer / commitComposition から呼ばれる未確定テキストの強制確定。
    /// candidate に明示的な選択（selectedRow > 0）がある場合はそちらを確定する。
    mutating func commitComposition(client: TextInputClient, candidate: CandidateContext = .hidden) {
        guard !state.composingText.isEmpty else { return }
        let inputKey = state.finalizedText
        if candidate.isVisible, let selected = candidate.selectedText {
            db.record(input: inputKey, output: selected)
            doCommit(text: selected, client: client)
        } else {
            db.record(input: inputKey, output: inputKey)
            doCommit(text: inputKey, client: client)
        }
    }

    // MARK: - プライベートヘルパー

    @discardableResult
    private mutating func doConfirmSelection(candidate: CandidateContext, client: TextInputClient) -> CandidateAction {
        guard !state.composingText.isEmpty else { return .none }
        let inputKey = state.finalizedText
        // Enter キーによる確定: 視覚的に選択中の候補をそのまま確定する
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
        let historyCount = result.historyCount

        let hiragana = state.composedHiragana
        let katakana = hiraganaToKatakana(hiragana)

        // 履歴にひらがな・カタカナが含まれるかを確認する
        // 履歴にある場合 → 履歴エントリとして可視範囲に残す（固定位置に追加しない）
        // 履歴にない場合 → スクロール範囲外の固定位置に追加し、↑ キーで到達できるようにする
        let hiraganaInHistory = candidates.prefix(historyCount).contains(hiragana)
        let katakanaInHistory = candidates.prefix(historyCount).contains(katakana)

        var fixedCount = 0
        if !katakanaInHistory {
            candidates.removeAll { $0 == katakana }
            candidates.insert(katakana, at: 0)
            fixedCount += 1
        }
        if !hiraganaInHistory {
            candidates.removeAll { $0 == hiragana }
            candidates.insert(hiragana, at: 0)
            fixedCount += 1
        }

        let historyEnd = fixedCount + historyCount
        // 履歴・辞書候補がある場合はその先頭を初期選択、固定候補のみなら先頭から表示
        let initialRow = candidates.count > fixedCount ? fixedCount : 0
        guard !candidates.isEmpty else { return .dismiss }
        return .show(candidates: candidates, historyEnd: historyEnd, initialRow: initialRow)
    }

    private func hiraganaToKatakana(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar in
            // ひらがな: U+3041〜U+3096 → カタカナ: U+30A1〜U+30F6 (offset +0x60)
            if scalar.value >= 0x3041 && scalar.value <= 0x3096 {
                return Character(UnicodeScalar(scalar.value + 0x60)!)
            }
            return Character(scalar)
        })
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

}
