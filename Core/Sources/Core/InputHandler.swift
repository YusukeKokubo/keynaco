import AppKit

/// 候補ウィンドウに対する操作指示
public enum CandidateAction: Sendable {
    case none
    case show(candidates: [String], historyEnd: Int, initialRow: Int, predictionEnd: Int, fixedEnd: Int)
    case dismiss
    case selectNext
    case selectPrev
    case deleteSelected
}

public struct CandidateContext: Sendable {
    public var isVisible: Bool
    public var selectedRow: Int
    public var selectedText: String?
    /// ユーザーが ↑↓ で明示的に候補を動かしたか（初期表示のまま = false）
    public var isExplicitlySelected: Bool
    /// 履歴セクションの末尾インデックス（これ未満の行が履歴）
    public var historyEnd: Int
    /// ユーザー辞書+カナ固定行の末尾インデックス（これ未満の行は Shift+Delete 不可）
    public var fixedEnd: Int

    public init(
        isVisible: Bool,
        selectedRow: Int,
        selectedText: String?,
        isExplicitlySelected: Bool = false,
        historyEnd: Int = 0,
        fixedEnd: Int = 0
    ) {
        self.isVisible = isVisible
        self.selectedRow = selectedRow
        self.selectedText = selectedText
        self.isExplicitlySelected = isExplicitlySelected
        self.historyEnd = historyEnd
        self.fixedEnd = fixedEnd
    }

    public static let hidden = CandidateContext(
        isVisible: false, selectedRow: 0, selectedText: nil,
        isExplicitlySelected: false, historyEnd: 0, fixedEnd: 0
    )
}

/// 確定直後 Backspace で `penalizeAll` するための、直前確定の学習コンテキスト。
public struct LastConfirmedContext: Equatable {
    public let input: String
    public let output: String
    public let fullReading: String?
}

public enum KeyCode {
    public static let eisu:      UInt16 = 102
    public static let kana:      UInt16 = 104
    public static let backspace: UInt16 = 51
    public static let space:     UInt16 = 49
    public static let enter:     UInt16 = 36
    public static let escape:    UInt16 = 53
    public static let tab:       UInt16 = 48
    public static let capsLock:  UInt16 = 57
    public static let downArrow: UInt16 = 125
    public static let upArrow:   UInt16 = 126
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let f6:  UInt16 = 97
    public static let f7:  UInt16 = 98
    public static let f8:  UInt16 = 100
    public static let f9:  UInt16 = 101
    public static let f10: UInt16 = 109
}

/// 入力処理の本体。IMK・UI に依存しない純粋なロジック。
///
/// 機能ごとの実装は extension で別ファイルに分散している：
/// - `InputHandler+SuccessorMode.swift`：後続語サジェストと 1 打目の保留マージ
/// - `InputHandler+SegmentMode.swift`  ：文節分割と境界調整
/// - `InputHandler+Candidates.swift`   ：候補リスト構築・候補表示中・通常入力
public struct InputHandler {

    // 全InputControllerインスタンスで共有するモード（アプリ切替後も保持）
    public nonisolated(unsafe) static var isAsciiMode = false

    public static let particles = ["が", "を", "に", "で", "へ", "と", "から", "まで", "より", "の", "は", "も"]
    /// ひらがな優先語彙セット。DB から読み込み、設定変更時に再取得する。
    public var hiraganaPreferredSet: Set<String> = []
    public static let sentenceTerminators: Set<String> = ["。", "！", "？"]
    /// 文脈をリセットせず、かつ N-gram・履歴にも記録しない句読点。
    /// pushCommitted でスキップすることで直前単語が prev のまま維持される。
    public static let readingPunctuations: Set<String> = ["、", "・", "…"]

    public var state = CompositionState()
    public var ignoreNextModeSwitch = false
    public var isSuccessorMode = false
    public var successorFirstChar: (keyCode: UInt16, characters: String?, baseCharacters: String?)? = nil
    public var pendingSuccessorCandidates: [String] = []
    public var bracketCandidates: [String]? = nil
    public var isBracketMode: Bool { bracketCandidates != nil }
    public var lastConfirmedContext: LastConfirmedContext? = nil
    /// 直前の確定の読み（`commitText` 時の `finalizedText`）。POS 分類後の noun_bigram 記録用。
    public var lastCommittedReading: String? = nil
    /// LLM 品詞分類で最後に確定した名詞の表層。noun_bigram の prev として使う。
    public var lastConfirmedNounOutput: String? = nil
    public var lastAzooKeyInput: String = ""
    /// `buildCandidateList` の AzooKey 候補キャッシュ照合用（`leftSideContext` が変わると再取得）
    public var lastAzooKeyContext: String = ""
    public var lastAzooKeyResults: [String] = []
    /// `resolvedLLMDocumentContextPrefix` 等から渡すカーソル左文（Zenzai）。空は文脈なし。
    public var leftSideContext: String = ""
    /// AzooKey API 用（空文字は `nil`）
    public var azooKeyLeftContext: String? { leftSideContext.isEmpty ? nil : leftSideContext }
    /// Zenzai がプロモートした候補の行インデックス。文脈なし・Zenzai 無効時は `nil`。
    public var lastZenzaiRow: Int? = nil
    public var committedHistory: [String] = []
    /// `pushCommitted` で文末記号により `committedHistory` を消した直後に立て、`InputController` が IMK 文脈キャッシュを捨てる。
    public var documentSurroundingContextInvalidated = false
    public var lastCommittedOutput: String? {
        committedHistory.last
    }
    public var segmentCandidateCache: [String: Segment] = [:]
    public mutating func pushCommitted(_ text: String) {
        if InputHandler.sentenceTerminators.contains(text) {
            committedHistory.removeAll()
            documentSurroundingContextInvalidated = true
            return
        }
        if InputHandler.readingPunctuations.contains(text) { return }
        committedHistory.append(text)
        if committedHistory.count > 5 { committedHistory.removeFirst() }
    }

    public func mostRecentContentWord() -> String? {
        mostRecentContentWords(n: 1).first
    }

    public func mostRecentContentWords(n: Int) -> [String] {
        var result: [String] = []
        for i in stride(from: committedHistory.count - 1, through: 0, by: -1) {
            if !InputHandler.particles.contains(committedHistory[i]) {
                result.append(committedHistory[i])
                if result.count >= n { break }
            }
        }
        return result
    }

    /// 学習用: `committedHistory` のみから content word を収集。
    func committedContentWords(n: Int) -> [String] {
        guard committedHistory.count >= 2 else { return [] }
        var result: [String] = []
        for i in stride(from: committedHistory.count - 2, through: 0, by: -1) {
            if !InputHandler.particles.contains(committedHistory[i]) {
                result.append(committedHistory[i])
                if result.count >= n { break }
            }
        }
        return result
    }
    public let db: DatabaseManager
    public var azooKeyConverter: any AzooKeyConverting

    public init(db: DatabaseManager = .shared, azooKeyConverter: (any AzooKeyConverting)? = nil) {
        self.db = db
        self.azooKeyConverter = azooKeyConverter ?? AzooKeyConverter()
        self.hiraganaPreferredSet = db.fetchHiraganaPreferredSet()
    }

    // MARK: - 公開インターフェース

    public mutating func handle(
        keyCode: UInt16,
        characters: String?,
        baseCharacters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        let isBackspace = keyCode == KeyCode.backspace || characters == "\u{08}"
        clearLastConfirmedContextUnlessBackspace(isBackspace: isBackspace)

        if isSuccessorMode {
            return handleSuccessorModeKey(
                keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                modifiers: modifiers, candidate: candidate, client: client)
        }
        if isBracketMode {
            return handleBracketModeKey(
                keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                modifiers: modifiers, candidate: candidate, client: client)
        }

        let wasExplicitlySelected = candidate.isVisible && candidate.isExplicitlySelected

        if let r = handleFunctionKeyIfNeeded(keyCode: keyCode, client: client) { return r }
        if state.isSegmentMode {
            return handleSegmentModeKey(
                keyCode: keyCode, modifiers: modifiers, candidate: candidate, client: client)
        }
        if let r = handleModeSwitchKey(keyCode: keyCode, client: client) { return r }
        ignoreNextModeSwitch = false
        if let r = handleAsciiModeKey(
            keyCode: keyCode, characters: characters, modifiers: modifiers, client: client) { return r }
        if let r = handleCandidateVisibleOrComposeOnlyKey(
            keyCode: keyCode, characters: characters, modifiers: modifiers, isBackspace: isBackspace,
            candidate: candidate, client: client) { return r }

        return handleNormalInput(
            keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
            modifiers: modifiers, wasExplicitlySelected: wasExplicitlySelected,
            candidate: candidate, client: client)
    }

    /// deactivateServer / commitComposition から呼ばれる未確定テキストの強制確定。
    /// candidate に明示的な選択（selectedRow > 0）がある場合はそちらを確定する。
    public mutating func commitComposition(client: TextInputClient, candidate: CandidateContext = .hidden) {
        // セグメントモード中の強制確定（アプリ切り替えなど）
        if let segmentState = state.segmentState {
            let selectedText = candidate.selectedText ?? segmentState.focusedSegment.selectedText
            var confirmed = ""
            var fullReading = ""
            for (i, seg) in segmentState.segments.enumerated() {
                let text = (i == segmentState.focusedIndex) ? selectedText : seg.selectedText
                db.recordPrefixes(reading: seg.reading, output: text)
                let conv = azooKeyConverter; let r = seg.reading; let t = text
                Task.detached(priority: .utility) { conv.commit(reading: r, text: t) }
                confirmed += text
                fullReading += seg.reading
            }
            if segmentState.segments.count >= 2 {
                db.recordPrefixes(reading: fullReading, output: confirmed)
            }
            commitText(text: confirmed, fullReading: fullReading, client: client)
            return
        }
        guard !state.composingText.isEmpty else { return }
        let inputKey = state.finalizedText
        let normalizedInput = inputKey.allSatisfy({ $0.isASCII }) ? inputKey.lowercased() : inputKey
        if candidate.isVisible, let selected = candidate.selectedText {
            let isDateTime = Self.generateDateTimeCandidates(for: normalizedInput).contains(selected)
            let isNumber = Self.generateNumberCandidates(for: normalizedInput).contains(selected)
            let isPunct = Self.readingPunctuations.contains(selected) || Self.sentenceTerminators.contains(selected)
            if !isDateTime && !isNumber && !isPunct { db.recordPrefixes(reading: normalizedInput, output: selected) }
            let conv = azooKeyConverter; let r = inputKey; let t = selected
            Task.detached(priority: .utility) { conv.commit(reading: r, text: t) }
            commitText(text: selected, skipHistory: isDateTime || isNumber, client: client)
        } else {
            let isPunct = Self.readingPunctuations.contains(inputKey) || Self.sentenceTerminators.contains(inputKey)
            if !isPunct { db.recordPrefixes(reading: normalizedInput, output: inputKey) }
            commitText(text: inputKey, client: client)
        }
    }

    // MARK: - 共通ヘルパー（extension からも参照される）

    public mutating func commitText(
        text: String,
        skipHistory: Bool = false,
        fullReading: String? = nil,
        client: TextInputClient
    ) {
        let isPunctuation = InputHandler.readingPunctuations.contains(text)
            || InputHandler.sentenceTerminators.contains(text)
        if !state.composingText.isEmpty && !skipHistory && !isPunctuation,
           committedHistory.last != nil {
            lastCommittedReading = state.finalizedText
        }
        lastConfirmedContext = LastConfirmedContext(
            input: state.finalizedText,
            output: text,
            fullReading: fullReading
        )
        pushCommitted(text)
        client.insertText(text)
        state = CompositionState()
    }

    /// F6–F10 の変換確定。composingText が空なら false を返す。
    public mutating func handleFunctionKey(keyCode: UInt16, client: TextInputClient) -> Bool {
        if state.isSegmentMode, let segmentState = state.segmentState {
            state.composedHiragana = segmentState.segments.map(\.reading).joined()
            state.segmentState = nil
            segmentCandidateCache.removeAll()
        }
        guard !state.composingText.isEmpty else { return false }
        state.absorbPendingIntoComposed()
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

    public func applyMarkedText(candidateText: String?, client: TextInputClient) {
        let text: String
        if let selected = candidateText {
            text = selected + state.pendingRomaji
        } else {
            text = state.composingText
        }
        client.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0))
    }

    public mutating func doBackspace(client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction) {
        let (handled, needsRefresh) = state.backspace()
        if !handled, let ctx = lastConfirmedContext {
            db.penalizeAll(
                input: ctx.input,
                output: ctx.output,
                fullReading: ctx.fullReading
            )
            lastConfirmedContext = nil
        }
        guard handled else { return (false, .none) }
        let action: CandidateAction = needsRefresh ? buildCandidateList() : .dismiss
        applyMarkedText(candidateText: nil, client: client)
        return (true, action)
    }

    public mutating func doEscape(client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction) {
        guard state.reset() else { return (false, .none) }
        applyMarkedText(candidateText: nil, client: client)
        return (true, .dismiss)
    }
}

// MARK: - handle() 分岐（薄型ディスパッチ用）

extension InputHandler {
    private mutating func clearLastConfirmedContextUnlessBackspace(isBackspace: Bool) {
        if !isBackspace { lastConfirmedContext = nil }
    }

    private mutating func handleSuccessorModeKey(
        keyCode: UInt16,
        characters: String?,
        baseCharacters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        handleSuccessorMode(
            keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
            modifiers: modifiers, candidate: candidate, client: client)
    }

    private mutating func handleFunctionKeyIfNeeded(
        keyCode: UInt16, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard !InputHandler.isAsciiMode,
              [KeyCode.f6, KeyCode.f7, KeyCode.f8, KeyCode.f9, KeyCode.f10].contains(keyCode) else { return nil }
        let consumed = handleFunctionKey(keyCode: keyCode, client: client)
        return (consumed, consumed ? suggestSuccessors() : .none)
    }

    private mutating func handleModeSwitchKey(
        keyCode: UInt16, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard keyCode == KeyCode.eisu || keyCode == KeyCode.kana else { return nil }
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

    private mutating func handleAsciiModeKey(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard InputHandler.isAsciiMode else { return nil }
        if keyCode == KeyCode.escape { InputHandler.isAsciiMode = false; return (true, .none) }
        if keyCode == KeyCode.enter {
            committedHistory.removeAll()
            documentSurroundingContextInvalidated = true
            return (false, .none)
        }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return (false, .none) }
        guard let chars = characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return (false, .none) }
        client.insertText(chars)
        return (true, .none)
    }

    private mutating func handleCandidateVisibleOrComposeOnlyKey(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        isBackspace: Bool,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        if candidate.isVisible {
            if let r = handleCandidateVisible(
                keyCode: keyCode, characters: characters,
                modifiers: modifiers, candidate: candidate, client: client) { return r }
            return nil
        }
        switch keyCode {
        case KeyCode.enter:
            guard !state.composingText.isEmpty else {
                committedHistory.removeAll()
                documentSurroundingContextInvalidated = true
                return (false, .none)
            }
            commitComposition(client: client)
            return (true, suggestSuccessors())
        case KeyCode.escape:
            return doEscape(client: client)
        default:
            if isBackspace { return doBackspace(client: client) }
            return nil
        }
    }
}
