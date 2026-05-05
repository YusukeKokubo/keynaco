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

/// 候補ウィンドウの現在状態スナップショット（読み取り専用）
/// Successor 用：オンデバイス LLM で後続語を補完するタイミング（`InputController` が参照してフェッチを開始する）。
public enum SuccessorLLMTrigger: Equatable {
    case none
    /// N-gram あり・閾値未満で保留（`.dismiss`）になった直後。`context` は `committedHistory.suffix(3)` のスナップショット。
    case pendingLowConfidence(context: [String])
    /// 格助詞のみ即時表示になった直後。
    case particlesOnly(context: [String])
}

/// セグメントモード用：`InputController` が `LLMSegmentConverter` を起動するタイミング。
public enum SegmentLLMTrigger: Equatable {
    case none
    case start(hiragana: String)
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
    public let prev1: String?
    public let prev2: String?
    public let skipPrevs: [String]
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
/// - `InputHandler+SuccessorMode.swift`：後続語サジェストと格助詞 fast-path
/// - `InputHandler+SegmentMode.swift`  ：文節分割と境界調整
/// - `InputHandler+Candidates.swift`   ：候補リスト構築・候補表示中・通常入力
public struct InputHandler {

    // 全InputControllerインスタンスで共有するモード（アプリ切替後も保持）
    public nonisolated(unsafe) static var isAsciiMode = false

    public static let particles = ["が", "を", "に", "で", "へ", "と", "から", "まで", "より", "の", "は", "も"]
    public static let sentenceTerminators: Set<String> = ["。", "！", "？"]
    public static let successorImmediateThreshold = LearningThresholds.successorImmediateThreshold

    public var state = CompositionState()
    public var ignoreNextModeSwitch = false
    public var isSuccessorMode = false
    public var successorFirstChar: (keyCode: UInt16, characters: String?, baseCharacters: String?)? = nil
    public var pendingSuccessorCandidates: [String] = []
    /// LLM が返した表層形のみ。`mergePendingSuccessorMatches` の `pending` には渡さない。
    public var successorLLMSurfaceExtras: [String] = []
    /// `particlesOnly` のとき即時表示した候補（LLM の表層形は `successorLLMSurfaceExtras`）。
    public var successorLLMBaseCandidates: [String]? = nil
    public var successorLLMTrigger: SuccessorLLMTrigger = .none
    public var segmentLLMTrigger: SegmentLLMTrigger = .none
    public var bracketCandidates: [String]? = nil
    public var isBracketMode: Bool { bracketCandidates != nil }
    public var lastConfirmedContext: LastConfirmedContext? = nil
    public var lastAzooKeyInput: String = ""
    /// `buildCandidateList` の AzooKey 候補キャッシュ照合用（`leftSideContext` が変わると再取得）
    public var lastAzooKeyContext: String = ""
    public var lastAzooKeyResults: [String] = []
    /// `resolvedLLMDocumentContextPrefix` 等から渡すカーソル左文（Zenzai）。空は文脈なし。
    public var leftSideContext: String = ""
    /// AzooKey API 用（空文字は `nil`）
    public var azooKeyLeftContext: String? { leftSideContext.isEmpty ? nil : leftSideContext }
    /// 候補スコアラー: `buildCandidateList` が返す候補列でのグローバル行（`pendingScorerStrings` と対応）
    public var pendingScorerGlobalIndices: [Int] = []
    public var pendingScorerStrings: [String] = []
    /// 直近の `buildCandidateList` でスコアラーを起動してよいか
    public var lastScorerEligible: Bool = false
    /// 直近の `buildCandidateList` が `.show` になったときの `autoShow` 引数（スコアラー確信度 guard 用）
    public var lastCandidateListAutoShow: Bool = false
    public var committedHistory: [String] = []
    /// `pushCommitted` で文末記号により `committedHistory` を消した直後に立て、`InputController` が IMK 文脈キャッシュを捨てる。
    public var documentSurroundingContextInvalidated = false
    public var lastCommittedOutput: String? { committedHistory.last }
    public var segmentCandidateCache: [String: Segment] = [:]
    public var prev2Output: String? {
        committedHistory.count >= 2 ? committedHistory[committedHistory.count - 2] : nil
    }
    public mutating func pushCommitted(_ text: String) {
        if InputHandler.sentenceTerminators.contains(text) {
            committedHistory.removeAll()
            documentSurroundingContextInvalidated = true
            return
        }
        committedHistory.append(text)
        if committedHistory.count > 5 { committedHistory.removeFirst() }
    }

    public func mostRecentContentWord() -> String? {
        mostRecentContentWords(n: 1).first
    }

    public func mostRecentContentWords(n: Int) -> [String] {
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

        // Dispatch order (early return wins):
        // 1. successor mode    → handleSuccessorMode
        // 2. F6–F10 (組成中)   → handleFunctionKey
        // 3. segment mode      → handleSegmentModeKey
        // 4. eisu / kana       → toggle ASCII mode
        // 5. ASCII mode        → passthrough
        // 6. candidate visible → handleCandidateVisible
        // 7. else              → handleNormalInput

        let isBackspace = keyCode == KeyCode.backspace || characters == "\u{08}"
        if !isBackspace { lastConfirmedContext = nil }

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

        // 候補ウィンドウ表示中
        if candidate.isVisible {
            if let result = handleCandidateVisible(keyCode: keyCode, characters: characters,
                                                   modifiers: modifiers, candidate: candidate, client: client) {
                return result
            }
        } else {
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
            }
        }

        return handleNormalInput(keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                                 modifiers: modifiers, wasExplicitlySelected: wasExplicitlySelected,
                                 candidate: candidate, client: client)
    }

    /// deactivateServer / commitComposition から呼ばれる未確定テキストの強制確定。
    /// candidate に明示的な選択（selectedRow > 0）がある場合はそちらを確定する。
    public mutating func commitComposition(client: TextInputClient, candidate: CandidateContext = .hidden) {
        // セグメントモード中の強制確定（アプリ切り替えなど）
        if let segmentState = state.segmentState {
            let selectedText = candidate.selectedText ?? segmentState.focusedSegment.selectedText
            if let llmText = segmentState.llmWholeText,
               isLlmWholeTextShortcut(segmentState: segmentState, candidateSelectedText: candidate.selectedText) {
                let fullReading = segmentState.segments.map(\.reading).joined()
                state.segmentState = nil
                segmentCandidateCache.removeAll()
                segmentLLMTrigger = .none
                db.recordPrefixes(reading: fullReading, output: llmText)
                azooKeyConverter.commit(reading: fullReading, text: llmText)
                commitText(text: llmText, fullReading: fullReading, client: client)
                return
            }
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
            segmentLLMTrigger = .none
            commitText(text: confirmed, fullReading: fullReading, client: client)
            return
        }
        guard !state.composingText.isEmpty else { return }
        let inputKey = state.finalizedText
        let normalizedInput = inputKey.allSatisfy({ $0.isASCII }) ? inputKey.lowercased() : inputKey
        if candidate.isVisible, let selected = candidate.selectedText {
            let isDateTime = Self.generateDateTimeCandidates(for: normalizedInput).contains(selected)
            let isNumber = Self.generateNumberCandidates(for: normalizedInput).contains(selected)
            if !isDateTime && !isNumber { db.recordPrefixes(reading: normalizedInput, output: selected) }
            let conv = azooKeyConverter; let r = inputKey; let t = selected
            Task.detached(priority: .utility) { conv.commit(reading: r, text: t) }
            commitText(text: selected, skipHistory: isDateTime || isNumber, client: client)
        } else {
            db.recordPrefixes(reading: normalizedInput, output: inputKey)
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
        var capPrev1: String?
        var capPrev2: String?
        var capSkipPrevs: [String] = []
        if !state.composingText.isEmpty && !skipHistory, let p1 = lastCommittedOutput {
            capPrev1 = p1
            capPrev2 = prev2Output
            if InputHandler.particles.contains(p1) { capSkipPrevs = mostRecentContentWords(n: 2) }
            let bigramInput = state.finalizedText
            db.recordNgrams(
                bigram: (prev: p1, input: bigramInput, output: text),
                trigram: prev2Output.map { (prev2: $0, prev1: p1, input: bigramInput, output: text) },
                skipBigrams: capSkipPrevs.map { (prev: $0, input: bigramInput, output: text) }
            )
        }
        lastConfirmedContext = LastConfirmedContext(
            input: state.finalizedText,
            output: text,
            prev1: capPrev1,
            prev2: capPrev2,
            skipPrevs: capSkipPrevs,
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
            segmentLLMTrigger = .none
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
                prev1: ctx.prev1,
                prev2: ctx.prev2,
                skipPrevs: ctx.skipPrevs,
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
        segmentLLMTrigger = .none
        applyMarkedText(candidateText: nil, client: client)
        return (true, .dismiss)
    }
}
