import AppKit

/// 候補ウィンドウに対する操作指示
public enum CandidateAction: Sendable {
    case none
    case show(
        candidates: [String],
        historyEnd: Int,
        initialRow: Int,
        fixedEnd: Int,
        zenzaiRow: Int? = nil,
        initialIsExplicitlySelected: Bool = false
    )
    case dismiss
    case selectNext
    case selectPrev
    case deleteSelected
    case replaceCandidates([String])
}

public extension CandidateAction {
    /// `.show` の連想値。それ以外は `nil`。
    var showPayload: (
        candidates: [String],
        historyEnd: Int,
        initialRow: Int,
        fixedEnd: Int,
        zenzaiRow: Int?,
        initialIsExplicitlySelected: Bool
    )? {
        if case .show(let candidates, let historyEnd, let initialRow, let fixedEnd, let zenzaiRow, let initialExplicit) = self {
            return (candidates, historyEnd, initialRow, fixedEnd, zenzaiRow, initialExplicit)
        }
        return nil
    }
}

public struct CandidateContext: Sendable {
    public var isVisible: Bool
    public var selectedRow: Int
    public var selectedText: String?
    /// ユーザーが ↑↓ で明示的に候補を動かしたか（初期表示のまま = false）。
    ///
    /// 役割: `true` のとき、文字キー入力で選択候補をまず確定してから新しい文字を処理する。
    /// `false` のときは文字入力しても候補を確定せず組成に追加する。
    /// Enter は `isExplicitlySelected` に関係なく `selectedText`（現在の視覚的選択）をそのまま確定する。
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

/// `buildCandidateList` の呼び出し元。候補列の組み立てロジックは共通、UI 抑制だけ分岐する。
public enum CandidateListTrigger: Sendable {
    /// 打鍵中。候補ゼロ・機能語のみのときはパネルを出さない。
    case whileTyping
    /// Space（候補非表示時）・バックスペース更新など。候補があれば出す。
    case explicit
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
/// - `InputHandler+Candidates.swift`   ：候補リスト構築・候補表示中・通常入力
public struct InputHandler {

    // 全InputControllerインスタンスで共有するモード（アプリ切替後も保持）
    public nonisolated(unsafe) static var isAsciiMode = false

    /// ひらがな優先語彙セット（DB `hiragana_preferred` テーブルから読み込み、設定変更時に再取得）。
    ///
    /// 役割: この集合に含まれる読みのとき、履歴スコア・予測候補の有無に関わらず
    /// `initialRow` をひらがな行にする（`assembleCandidateList`）。
    public var hiraganaPreferredSet: Set<String> = []
    public static let sentenceTerminators: Set<String> = ["。", "！", "？"]
    /// 文脈をリセットせず、かつ N-gram・履歴にも記録しない句読点。
    /// pushCommitted でスキップすることで直前単語が prev のまま維持される。
    public static let readingPunctuations: Set<String> = ["、", "・", "…"]

    public var state = CompositionState()
    public var candidateSession = CandidateSession()
    public var ignoreNextModeSwitch = false
    public var bracketCandidates: [String]? {
        get { candidateSession.bracketCandidates }
        set { candidateSession.bracketCandidates = newValue }
    }
    public var isBracketMode: Bool { candidateSession.isBracketMode }
    /// 確定直後の Backspace を「誤変換の訂正」として扱うために保持する直前 1 件の学習キー。
    /// 不変条件: Backspace 以外のキー入力・ペナルティ実行後は `nil`。
    public var lastConfirmedContext: LastConfirmedContext? = nil
    /// 直前の確定の読み（`commitText` 時の `finalizedText`）。
    public var lastCommittedReading: String? = nil
    public var lastAzooKeyInput: String = ""
    /// `buildCandidateList` の AzooKey 候補キャッシュ照合用（`leftSideContext` が変わると再取得）
    public var lastAzooKeyContext: String = ""
    public var lastAzooKeyResults: [String] = []
    /// `resolvedLLMDocumentContextPrefix` 等から渡すカーソル左文（Zenzai）。空は文脈なし。
    public var leftSideContext: String = ""
    /// AzooKey API 用（空文字は `nil`）
    public var azooKeyLeftContext: String? { leftSideContext.isEmpty ? nil : leftSideContext }
    public var committedHistory: [String] = []
    /// Zenzai 左文脈用のセッションバッファ（上限 50 字・文末でリセットしない）。
    public var sessionTextBuffer: String = ""
    /// `pushCommitted` で文末記号により `committedHistory` を消した直後に立て、`InputController` が IMK 文脈キャッシュを捨てる。
    public var documentSurroundingContextInvalidated = false
    public var lastCommittedOutput: String? {
        committedHistory.last
    }
    /// 日記用バッファ: 句点（。！？）で区切られた文を蓄積し、文末でまとめて daily_log へ記録する。
    public var diaryBuffer: String = ""
    /// daily_log に記録する際のアプリ bundle ID。InputController がキーイベント処理前に設定する。
    public var currentAppBundleID: String?
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

    public mutating func appendToSessionBuffer(_ text: String) {
        guard !InputHandler.readingPunctuations.contains(text) else { return }
        sessionTextBuffer += text
        if sessionTextBuffer.count > 50 {
            sessionTextBuffer = String(sessionTextBuffer.suffix(50))
        }
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

        if isBracketMode {
            return handleBracketModeKey(
                keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                modifiers: modifiers, candidate: candidate, client: client)
        }

        let wasExplicitlySelected = candidate.isVisible && candidate.isExplicitlySelected

        if let r = handleFunctionKeyIfNeeded(keyCode: keyCode, client: client) { return r }
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
        if !text.isEmpty {
            if InputHandler.sentenceTerminators.contains(text) {
                if !diaryBuffer.isEmpty {
                    db.recordDailyLog(output: diaryBuffer + text, appBundleID: currentAppBundleID)
                    diaryBuffer = ""
                }
            } else {
                diaryBuffer += text
            }
        }
        pushCommitted(text)
        appendToSessionBuffer(text)
        client.insertText(text)
        state = CompositionState()
    }

    /// F6–F10 の変換確定。composingText が空なら false を返す。
    public mutating func handleFunctionKey(keyCode: UInt16, client: TextInputClient) -> Bool {
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

    /// アプリ切り替え時など、文末記号なしに入力が途切れた際にバッファを flush する。
    public mutating func flushDiaryBuffer() {
        guard !diaryBuffer.isEmpty else { return }
        db.recordDailyLog(output: diaryBuffer, appBundleID: currentAppBundleID)
        diaryBuffer = ""
    }

    /// `CandidateAction` を `candidateSession` に反映し marked text を同期する。
    /// `.deleteSelected` の DB 削除もここ。候補ウィンドウ更新は `InputController` のみ。
    public mutating func applyCandidateAction(_ action: CandidateAction, client: TextInputClient) {
        if case .deleteSelected = action,
           let text = candidateSession.selectedText {
            db.deleteHistory(output: text)
        }
        candidateSession.apply(action)
        syncMarkedText(client: client)
    }

    /// 組成バッファと `candidateSession` の選択行から marked text を組み立てる。
    /// 通常は `applyCandidateAction` 経由。キー外（候補 UI 削除など）は `syncMarkedText` を直接呼ぶ。
    public func syncMarkedText(client: TextInputClient) {
        let session = candidateSession
        let text = MarkedTextSync.resolve(
            isBracketMode: isBracketMode,
            candidateVisible: session.isVisible,
            isExplicitlySelected: session.isExplicitlySelected,
            composedHiragana: state.composedHiragana,
            pendingRomaji: state.pendingRomaji,
            composingText: state.composingText,
            selectedCandidate: session.selectedText
        )
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
        let trigger: CandidateListTrigger =
            candidateSession.isVisible && !candidateSession.isExplicitlySelected ? .whileTyping : .explicit
        let action: CandidateAction = needsRefresh ? buildCandidateList(trigger: trigger) : .dismiss
        return (true, action)
    }

    public mutating func doEscape(client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction) {
        guard state.reset() else { return (false, .none) }
        return (true, .dismiss)
    }
}

// MARK: - handle() 分岐（薄型ディスパッチ用）

extension InputHandler {
    private mutating func clearLastConfirmedContextUnlessBackspace(isBackspace: Bool) {
        if !isBackspace { lastConfirmedContext = nil }
    }

    private mutating func handleFunctionKeyIfNeeded(
        keyCode: UInt16, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard !InputHandler.isAsciiMode,
              [KeyCode.f6, KeyCode.f7, KeyCode.f8, KeyCode.f9, KeyCode.f10].contains(keyCode) else { return nil }
        let consumed = handleFunctionKey(keyCode: keyCode, client: client)
        return (consumed, consumed ? .dismiss : .none)
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
            sessionTextBuffer = ""
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
                sessionTextBuffer = ""
                documentSurroundingContextInvalidated = true
                return (false, .none)
            }
            commitComposition(client: client)
            return (true, .dismiss)
        case KeyCode.escape:
            return doEscape(client: client)
        default:
            if isBackspace { return doBackspace(client: client) }
            return nil
        }
    }
}
