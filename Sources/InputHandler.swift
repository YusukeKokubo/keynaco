import AppKit

/// 候補ウィンドウに対する操作指示
enum CandidateAction {
    case none
    case show(candidates: [String], historyEnd: Int, initialRow: Int, predictionEnd: Int, fixedEnd: Int)
    case dismiss
    case selectNext
    case selectPrev
    case deleteSelected
}

/// 候補ウィンドウの現在状態スナップショット（読み取り専用）
struct CandidateContext {
    var isVisible: Bool
    var selectedRow: Int
    var selectedText: String?
    /// ユーザーが ↑↓ で明示的に候補を動かしたか（初期表示のまま = false）
    var isExplicitlySelected: Bool = false
    /// 履歴セクションの末尾インデックス（これ未満の行が履歴）
    var historyEnd: Int = 0
    /// ユーザー辞書+カナ固定行の末尾インデックス（これ未満の行は Shift+Delete 不可）
    var fixedEnd: Int = 0

    static let hidden = CandidateContext(isVisible: false, selectedRow: 0, selectedText: nil)
}

enum KeyCode {
    static let eisu:      UInt16 = 102
    static let kana:      UInt16 = 104
    static let backspace: UInt16 = 51
    static let space:     UInt16 = 49
    static let enter:     UInt16 = 36
    static let escape:    UInt16 = 53
    static let tab:       UInt16 = 48
    static let capsLock:  UInt16 = 57
    static let downArrow: UInt16 = 125
    static let upArrow:   UInt16 = 126
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let f6:  UInt16 = 97
    static let f7:  UInt16 = 98
    static let f8:  UInt16 = 100
    static let f9:  UInt16 = 101
    static let f10: UInt16 = 109
}

/// 入力処理の本体。IMK・UI に依存しない純粋なロジック。
///
/// 機能ごとの実装は extension で別ファイルに分散している：
/// - `InputHandler+SuccessorMode.swift`：後続語サジェストと格助詞 fast-path
/// - `InputHandler+SegmentMode.swift`  ：文節分割と境界調整
/// - `InputHandler+Candidates.swift`   ：候補リスト構築・候補表示中・通常入力
struct InputHandler {

    // 全InputControllerインスタンスで共有するモード（アプリ切替後も保持）
    nonisolated(unsafe) static var isAsciiMode = false

    static let particles = ["が", "を", "に", "で", "へ", "と", "から", "まで", "より", "の", "は", "も"]
    static let sentenceTerminators: Set<String> = ["。", "！", "？", "\n"]
    static let successorImmediateThreshold = 5

    var state = CompositionState()
    var ignoreNextModeSwitch = false
    var isSuccessorMode = false
    var successorFirstChar: (keyCode: UInt16, characters: String?, baseCharacters: String?)? = nil
    var pendingSuccessorCandidates: [String] = []
    var bracketCandidates: [String]? = nil
    var isBracketMode: Bool { bracketCandidates != nil }
    var lastConfirmedPair: (input: String, output: String)? = nil
    var lastAzooKeyInput: String = ""
    var lastAzooKeyResults: [String] = []
    var committedHistory: [String] = []
    var lastCommittedOutput: String? { committedHistory.last }
    var segmentCandidateCache: [String: Segment] = [:]
    var prev2Output: String? {
        committedHistory.count >= 2 ? committedHistory[committedHistory.count - 2] : nil
    }
    mutating func pushCommitted(_ text: String) {
        if InputHandler.sentenceTerminators.contains(text) {
            committedHistory.removeAll()
            return
        }
        committedHistory.append(text)
        if committedHistory.count > 5 { committedHistory.removeFirst() }
    }

    func mostRecentContentWord() -> String? {
        guard committedHistory.count >= 2 else { return nil }
        for i in stride(from: committedHistory.count - 2, through: 0, by: -1) {
            if !InputHandler.particles.contains(committedHistory[i]) { return committedHistory[i] }
        }
        return nil
    }
    let db: DatabaseManager
    let azooKeyConverter: any AzooKeyConverting

    init(db: DatabaseManager = .shared, azooKeyConverter: (any AzooKeyConverting)? = nil) {
        self.db = db
        self.azooKeyConverter = azooKeyConverter ?? AzooKeyConverter()
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

        // Dispatch order (early return wins):
        // 1. successor mode    → handleSuccessorMode
        // 2. F6–F10 (組成中)   → handleFunctionKey
        // 3. segment mode      → handleSegmentModeKey
        // 4. eisu / kana       → toggle ASCII mode
        // 5. ASCII mode        → passthrough
        // 6. candidate visible → handleCandidateVisible
        // 7. else              → handleNormalInput

        let isBackspace = keyCode == KeyCode.backspace || characters == "\u{08}"
        if !isBackspace { lastConfirmedPair = nil }

        if isSuccessorMode {
            return handleSuccessorMode(keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                                      modifiers: modifiers, candidate: candidate, client: client)
        }

        if isBracketMode {
            return handleBracketModeKey(keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                                        modifiers: modifiers, candidate: candidate, client: client)
        }

        let wasExplicitlySelected = candidate.isVisible && candidate.isExplicitlySelected

        // F6–F10 変換キー（組成中のみ動作）
        if !InputHandler.isAsciiMode,
           [KeyCode.f6, KeyCode.f7, KeyCode.f8, KeyCode.f9, KeyCode.f10].contains(keyCode) {
            let consumed = handleFunctionKey(keyCode: keyCode, client: client)
            return (consumed, consumed ? suggestSuccessors() : .none)
        }

        // セグメントモード中は最優先でハンドリング
        if state.isSegmentMode {
            return handleSegmentModeKey(keyCode: keyCode, modifiers: modifiers, candidate: candidate, client: client)
        }

        // 英数キー / かなキー
        if keyCode == KeyCode.eisu || keyCode == KeyCode.kana {
            if ignoreNextModeSwitch {
                ignoreNextModeSwitch = false
                return (true, .none)
            }
            if keyCode == KeyCode.eisu {
                if !state.composingText.isEmpty { commitComposition(client: client) }
                InputHandler.isAsciiMode = true
            } else {
                InputHandler.isAsciiMode = false
            }
            return (true, .none)
        }
        ignoreNextModeSwitch = false

        // 英字モード
        if InputHandler.isAsciiMode {
            if keyCode == KeyCode.escape { InputHandler.isAsciiMode = false; return (true, .none) }
            guard modifiers.intersection([.command, .control, .option]).isEmpty else { return (false, .none) }
            guard let chars = characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return (false, .none) }
            client.insertText(chars)
            return (true, .none)
        }

        // 候補ウィンドウ表示中
        if candidate.isVisible {
            if let result = handleCandidateVisible(keyCode: keyCode, characters: characters,
                                                   modifiers: modifiers, candidate: candidate, client: client) {
                return result
            }
        } else {
            switch keyCode {
            case KeyCode.enter:
                guard !state.composingText.isEmpty else { return (false, .none) }
                commitComposition(client: client)
                return (true, suggestSuccessors())
            case KeyCode.escape:
                return doEscape(client: client)
            default:
                if isBackspace { return doBackspace(client: client) }
            }
        }

        return handleNormalInput(keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                                 modifiers: modifiers, wasExplicitlySelected: wasExplicitlySelected,
                                 candidate: candidate, client: client)
    }

    /// deactivateServer / commitComposition から呼ばれる未確定テキストの強制確定。
    /// candidate に明示的な選択（selectedRow > 0）がある場合はそちらを確定する。
    mutating func commitComposition(client: TextInputClient, candidate: CandidateContext = .hidden) {
        // セグメントモード中の強制確定（アプリ切り替えなど）
        if let segmentState = state.segmentState {
            let selectedText = candidate.selectedText ?? segmentState.focusedSegment.selectedText
            var confirmed = ""
            var fullReading = ""
            for (i, seg) in segmentState.segments.enumerated() {
                let text = (i == segmentState.focusedIndex) ? selectedText : seg.selectedText
                db.recordPrefixes(reading: seg.reading, output: text)
                azooKeyConverter.commit(reading: seg.reading, text: text)
                confirmed += text
                fullReading += seg.reading
            }
            if segmentState.segments.count >= 2 {
                db.recordPrefixes(reading: fullReading, output: confirmed)
            }
            commitText(text: confirmed, client: client)
            return
        }
        guard !state.composingText.isEmpty else { return }
        let inputKey = state.finalizedText
        let normalizedInput = inputKey.allSatisfy({ $0.isASCII }) ? inputKey.lowercased() : inputKey
        if candidate.isVisible, let selected = candidate.selectedText {
            let isDateTime = Self.generateDateTimeCandidates(for: normalizedInput).contains(selected)
            let isNumber = Self.generateNumberCandidates(for: normalizedInput).contains(selected)
            if !isDateTime && !isNumber { db.recordPrefixes(reading: normalizedInput, output: selected) }
            azooKeyConverter.commit(reading: inputKey, text: selected)
            commitText(text: selected, skipHistory: isDateTime || isNumber, client: client)
        } else {
            db.recordPrefixes(reading: normalizedInput, output: inputKey)
            commitText(text: inputKey, client: client)
        }
    }

    // MARK: - 共通ヘルパー（extension からも参照される）

    mutating func commitText(text: String, skipHistory: Bool = false, client: TextInputClient) {
        if !state.composingText.isEmpty && !skipHistory {
            if let p1 = lastCommittedOutput {
                db.withTransaction {
                    db.recordBigram(prev: p1, input: state.finalizedText, output: text)
                    if let p2 = prev2Output {
                        db.recordTrigram(prev2: p2, prev1: p1, input: state.finalizedText, output: text)
                    }
                    if InputHandler.particles.contains(p1), let prevContent = mostRecentContentWord() {
                        db.recordSkipBigram(prev: prevContent, input: state.finalizedText, output: text)
                    }
                }
            }
        }
        lastConfirmedPair = (state.finalizedText, text)
        pushCommitted(text)
        client.insertText(text)
        state = CompositionState()
    }

    /// F6–F10 の変換確定。composingText が空なら false を返す。
    mutating func handleFunctionKey(keyCode: UInt16, client: TextInputClient) -> Bool {
        if state.isSegmentMode, let segmentState = state.segmentState {
            state.composedHiragana = segmentState.segments.map(\.reading).joined()
            state.segmentState = nil
            segmentCandidateCache.removeAll()
        }
        guard !state.composingText.isEmpty else { return false }
        if !state.pendingRomaji.isEmpty {
            state.composedHiragana += RomajiConverter.forceFinalize(state.pendingRomaji)
            state.pendingRomaji = ""
        }
        let hiragana = state.composedHiragana
        let text: String
        switch keyCode {
        case KeyCode.f6:  text = hiragana
        case KeyCode.f7:  text = KanaUtils.hiraganaToKatakana(hiragana)
        case KeyCode.f8:  text = KanaUtils.hiraganaToHankakuKatakana(hiragana)
        case KeyCode.f9:  text = KanaUtils.toZenkakuAscii(RomajiConverter.hiraganaToRomaji(hiragana))
        case KeyCode.f10: text = RomajiConverter.hiraganaToRomaji(hiragana)
        default: return false
        }
        db.recordPrefixes(reading: hiragana, output: text)
        commitText(text: text, client: client)
        return true
    }

    func applyMarkedText(candidateText: String?, client: TextInputClient) {
        let text: String
        if let selected = candidateText {
            text = selected + state.pendingRomaji
        } else {
            text = state.composingText
        }
        client.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0))
    }

    mutating func doBackspace(client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction) {
        let (handled, needsRefresh) = state.backspace()
        if !handled, let pair = lastConfirmedPair {
            db.penalizeHistory(input: pair.input, output: pair.output)
            lastConfirmedPair = nil
        }
        guard handled else { return (false, .none) }
        let action: CandidateAction = needsRefresh ? buildCandidateList() : .dismiss
        applyMarkedText(candidateText: nil, client: client)
        return (true, action)
    }

    mutating func doEscape(client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction) {
        guard state.reset() else { return (false, .none) }
        applyMarkedText(candidateText: nil, client: client)
        return (true, .dismiss)
    }
}
