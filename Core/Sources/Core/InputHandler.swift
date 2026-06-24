import AppKit

/// 候補ウィンドウに対する操作指示
public enum CandidateAction: Sendable {
    case none
    case show(
        candidates: [String],
        initialRow: Int,
        fixedEnd: Int,
        /// AzooKey API が返した順序（LCID ソート前）。Zenzai 有効 + 左文脈ありのときのみ非空。
        azooKeyApiOrder: [String] = [],
        initialIsExplicitlySelected: Bool = false,
        candidateSources: [ScoredCandidate.Source] = []
    )
    case dismiss
    case selectNext
    case selectPrev
    case deleteSelected
}

extension CandidateAction {
    /// `.show` の連想値。それ以外は `nil`。
    var showPayload: (
        candidates: [String],
        initialRow: Int,
        fixedEnd: Int,
        azooKeyApiOrder: [String],
        initialIsExplicitlySelected: Bool,
        candidateSources: [ScoredCandidate.Source]
    )? {
        if case .show(let candidates, let initialRow, let fixedEnd, let apiOrder, let initialExplicit, let sources) = self {
            return (candidates, initialRow, fixedEnd, apiOrder, initialExplicit, sources)
        }
        return nil
    }
}

public struct CandidateContext: Sendable {
    public private(set) var isVisible: Bool
    public private(set) var selectedRow: Int
    public private(set) var selectedText: String?
    /// ユーザーが ↑↓ で明示的に候補を動かしたか（初期表示のまま = false）。
    ///
    /// 役割: `true` のとき、文字キー入力で選択候補をまず確定してから新しい文字を処理する。
    /// `false` のときは文字入力しても候補を確定せず組成に追加する。
    /// Enter は `isExplicitlySelected` に関係なく `selectedText`（現在の視覚的選択）をそのまま確定する。
    public private(set) var isExplicitlySelected: Bool
    /// 先頭から連続するひらがな preferred 行数（Zenzai 診断・UI 補助）。
    public private(set) var fixedEnd: Int
    /// 行ごとの source。Shift+Delete とセクション描画の正本。
    public private(set) var candidateSources: [ScoredCandidate.Source] = []

    public init(
        isVisible: Bool,
        selectedRow: Int,
        selectedText: String?,
        isExplicitlySelected: Bool = false,
        fixedEnd: Int = 0,
        candidateSources: [ScoredCandidate.Source] = []
    ) {
        self.isVisible = isVisible
        self.selectedRow = selectedRow
        self.selectedText = selectedText
        self.isExplicitlySelected = isExplicitlySelected
        self.fixedEnd = fixedEnd
        self.candidateSources = candidateSources
    }

    public func isHistoryDeletable(at row: Int) -> Bool {
        guard candidateSources.indices.contains(row) else { return false }
        return CandidateRowMetadata.isHistoryDeletable(source: candidateSources[row])
    }

    public static let hidden = CandidateContext(
        isVisible: false, selectedRow: 0, selectedText: nil,
        isExplicitlySelected: false, fixedEnd: 0, candidateSources: []
    )

    /// `CandidateSession.panelInteraction` と同じ導出（`handle()` へのスナップショット用）。
    public var panelInteraction: CandidatePanelInteraction {
        guard isVisible else { return .hidden }
        return isExplicitlySelected ? .explicit : .passive
    }
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
/// - `InputHandler+KeyDispatch.swift`    ：`handle()` ルーティング
/// - `InputHandler+NormalInput.swift`    ：ローマ字・記号・z シーケンス入力
/// - `InputHandler+CandidateInput.swift` ：候補表示中のキー処理
/// - `InputHandler+Candidates.swift`     ：候補リスト構築
/// - `InputHandler+BracketMode.swift`    ：括弧モード
public struct InputHandler {

    /// 英字直接入力モード。プロセス全体で 1 つの static（全 `InputController` / アプリ切替後も維持）。
    ///
    /// 不変条件:
    /// - 英数キー（`KeyCode.eisu`）・かなキー（`KeyCode.kana`）・Escape（ASCII 中）・Caps Lock（`InputController.flagsChanged`）で更新
    /// - `activateServer` 直後の `ignoreNextModeSwitch` とは独立（IMK のモードキー echo 抑制専用）
    /// - ユニットテストは `setUp` で必ず `false` にリセットする
    ///
    /// `nonisolated(unsafe)`: IMK コールバックと `flagsChanged` が異なる isolation から触るため。
    /// インスタンス状態へ移さない（意図的なグローバルモード）。
    public nonisolated(unsafe) static var isAsciiMode = false

    /// ひらがな優先語彙セット（DB `hiragana_preferred` テーブルから読み込み、設定変更時に再取得）。
    ///
    /// 役割: この集合に含まれる読みのとき、履歴スコア・予測候補の有無に関わらず
    /// `initialRow` をひらがな行にする（`assembleCandidateList`）。
    public var hiraganaPreferredSet: Set<String> = []
    static let sentenceTerminators: Set<String> = ["。", "！", "？"]
    /// 文脈をリセットせず、かつ N-gram・履歴にも記録しない句読点。
    /// pushCommitted でスキップすることで直前単語が prev のまま維持される。
    static let readingPunctuations: Set<String> = ["、", "・", "…"]

    public var state = CompositionState()
    public var candidateSession = CandidateSession()
    /// `activateServer` 直後に IMK が英数/かなキーを echo するのを 1 回だけ無視する（bc3c628）。
    /// 英数キー押下そのものの二重送信ではない。
    ///
    /// | 操作 | 値 |
    /// |------|-----|
    /// | **set `true`** | `InputController.activateServer` のみ |
    /// | **clear `false`** | 英数/かなキーで echo 抑制消費時（`handleModeSwitchKey`）、それ以外の任意キー（`handle()` 本流） |
    public var ignoreNextModeSwitch = false
    /// 本番 `InputController` のみ `true`。`.whileTyping` で AzooKey を同期呼ばず `pendingAzooKeyReading` を返す。
    public var deferAzooKeyWhileTyping = false
    /// 直近 `syncMarkedText` で IMK に送った内容。同一なら `setMarkedText` をスキップしてちらつきを抑える。
    private var lastSyncedMarkedText: String?
    private var lastSyncedMarkedSelection: NSRange?
    /// 直近 `handle()` の AzooKey 非同期取得対象読み（`deferAzooKeyWhileTyping` 有効時のみ非 nil になり得る）。
    public private(set) var pendingAzooKeyReading: String?
    #if DEBUG
    /// 直近の `assembleCandidateList` で初期行を決めたときの診断情報。
    public internal(set) var lastCandidateBuildDiagnostics: CandidateBuildDiagnostics?
    #endif

    mutating func clearPendingAzooKeyReading() {
        pendingAzooKeyReading = nil
    }

    mutating func notePendingAzooKeyReading(_ reading: String?) {
        pendingAzooKeyReading = reading
    }
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
    /// 現在変換セッションの打鍵蓄積。セッション終了（確定/Escape）でリセット。
    public var sessionTracker = InputSessionTracker()
    /// 直近セッション終了後に `InputController` へ渡す記録（書き込み前）。
    public var pendingSessionRecord: InputSessionRecord? = nil

    /// `commitComposition` で Z1 ≠ confirmed を検出した直近 1 件。`InputController` が引き取って flush する。
    public var pendingDivergenceRecord: CandidateDivergenceRecord? = nil
    /// 直近 `assembleCandidateList` で決定した初期行の理由。divergence log に `rawValue` で付与する。
    var lastInitialRowReason: InitialRowReason = .afterFixed
    /// 直近 `doBackspace` で `penalizeAll` が実行されたか。次キーで `InputController` が前セッション record に反映。
    public var lastKeyDownDidPenalize = false
    /// 左文脈の解決結果。`LeftContextSource` で組み立て、`InputController` / サンドボックスが各 keyDown 前に設定。
    public var leftContext: LeftContext = .empty
    /// IMK surrounding キャッシュ。`.invalidated` は `LeftContextSource.applyPostKeyDown` が `.empty` に遷移させる。
    ///
    /// | 操作 | 箇所 |
    /// |------|------|
    /// | **`.invalidated` にセット** | `pushCommitted` の文末記号（`。` `！` `？`）、ASCII モード Enter、組成空 Enter |
    /// | **`.empty` に遷移** | `LeftContextSource.applyPostKeyDown` |
    public var leftContextIMKCache = LeftContextIMKCache()
    public var committedHistory: [String] = []
    /// Zenzai 左文脈用。確定語ごとに加算（上限 50 字）。`leftContext.sessionBuffer` の素材 — 詳細は `LeftContextSource` MARK。
    public var sessionTextBuffer: String = ""
    var lastCommittedOutput: String? {
        committedHistory.last
    }
    /// 日記用バッファ: 句点（。！？）で区切られた文を蓄積し、文末でまとめて daily_log へ記録する。
    public var diaryBuffer: String = ""
    /// daily_log に記録する際のアプリ bundle ID。InputController がキーイベント処理前に設定する。
    public var currentAppBundleID: String?
    public mutating func pushCommitted(_ text: String) {
        if InputHandler.sentenceTerminators.contains(text) {
            committedHistory.removeAll()
            leftContextIMKCache = .invalidated
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

    // MARK: - 公開インターフェース（`handle` は InputHandler+KeyDispatch.swift）

    /// 未確定テキストを確定する。candidate に明示的な選択がある場合はそちらを確定する。
    /// - Parameter trigger: 呼び出し元の確定経路（`CommitTrigger`）
    public mutating func commitComposition(client: TextInputClient, candidate: CandidateContext = .hidden, trigger: CommitTrigger = .enter) {
        guard state.isComposing else { return }
        azooKeyConverter.latencyStats.recordConfirmation(selectionDepth: candidate.isVisible ? candidate.selectedRow : nil)
        let inputKey = state.finalizedText
        let normalizedInput = inputKey.allSatisfy({ $0.isASCII }) ? inputKey.lowercased() : inputKey
        // commitText が lastCommittedReading を更新するため先に退避する
        let prevReadingForReTyped = lastCommittedReading
        let committedText: String
        if candidate.isVisible, let selected = candidate.selectedText {
            let isDateTime = Self.generateDateTimeCandidates(for: normalizedInput).contains(selected)
            let isNumber = Self.generateNumberCandidates(for: normalizedInput).contains(selected)
            let isPunct = Self.readingPunctuations.contains(selected) || Self.sentenceTerminators.contains(selected)
            if !isDateTime && !isNumber && !isPunct {
                let reading = resolvedHistoryReading(userReading: normalizedInput, inputKey: inputKey, output: selected)
                db.recordPrefixes(reading: reading, output: selected)
            }
            let conv = azooKeyConverter; let r = inputKey; let t = selected
            Task.detached(priority: .utility) { conv.commit(reading: r, text: t) }
            commitText(text: selected, skipHistory: isDateTime || isNumber, client: client)
            committedText = selected
        } else {
            let isPunct = Self.readingPunctuations.contains(inputKey) || Self.sentenceTerminators.contains(inputKey)
            if !isPunct { db.recordPrefixes(reading: normalizedInput, output: inputKey) }
            commitText(text: inputKey, client: client)
            committedText = inputKey
        }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        var anomaly: [String] = []
        if sessionTracker.scrollCount >= 4 { anomaly.append("deep_scroll") }
        if !inputKey.isEmpty, inputKey == prevReadingForReTyped { anomaly.append("re_typed") }
        pendingSessionRecord = InputSessionRecord(
            ts: nowMs,
            keyCount: sessionTracker.keyCount,
            bsCount: sessionTracker.bsCount,
            compositionMs: sessionTracker.compositionMs(endMs: nowMs),
            reading: inputKey,
            committed: committedText,
            candidateDepth: candidate.isVisible ? candidate.selectedRow : nil,
            wasExplicit: candidate.isExplicitlySelected,
            scrollCount: sessionTracker.scrollCount,
            anomaly: anomaly,
            bsExplicitCount: sessionTracker.bsExplicitCount,
            bsShrunkToOneCount: sessionTracker.bsShrunkToOneCount
        )
        recordCandidateDivergenceIfAny(
            reading: inputKey,
            committedText: committedText,
            wasExplicit: candidate.isExplicitlySelected,
            nowMs: nowMs
        )
        sessionTracker.reset()
    }

    /// Zenzai が推した Z1（`candidateSession.azooKeyApiOrder.first`）と実確定が違うときだけ 1 件残す。
    /// Zenzai 無効 / 文脈なし時（`azooKeyApiOrder` 空）と、句読点・数字・日時の確定は対象外。
    private mutating func recordCandidateDivergenceIfAny(
        reading: String,
        committedText: String,
        wasExplicit: Bool,
        nowMs: Int
    ) {
        let apiOrder = candidateSession.azooKeyApiOrder
        guard let z1 = apiOrder.first, z1 != committedText else { return }
        let isPunct = Self.readingPunctuations.contains(committedText)
            || Self.sentenceTerminators.contains(committedText)
        guard !isPunct else { return }
        let candidatesTop = Array(candidateSession.candidates.prefix(8))
        let row = candidateSession.selectedRow
        let confirmedSource: String
        if candidateSession.candidateSources.indices.contains(row) {
            switch CandidateRowMetadata.section(for: candidateSession.candidateSources[row]) {
            case .fixed: confirmedSource = "fixed"
            case .history: confirmedSource = "history"
            case .dictionary: confirmedSource = "dict"
            }
        } else if row < candidateSession.fixedEnd {
            confirmedSource = "fixed"
        } else {
            confirmedSource = "dict"
        }
        #if DEBUG
        let scoredSources = lastCandidateBuildDiagnostics?.scoredSources
        #else
        let scoredSources: [String]? = nil
        #endif
        pendingDivergenceRecord = CandidateDivergenceRecord(
            ts: nowMs,
            reading: reading,
            z1: z1,
            confirmed: committedText,
            selectedRow: row,
            wasExplicit: wasExplicit,
            candidates: candidatesTop,
            leftContext: leftContext.azooKeyValue,
            confirmedSource: confirmedSource,
            initialRow: candidateSession.initialRow,
            initialRowReason: lastInitialRowReason.rawValue,
            scoredSources: scoredSources
        )
    }

    /// prefix-focus で短い読みで確定した場合に canonical reading（AzooKey のキャッシュ ruby）を返す。
    /// `userReading` が canonical の前方一致になっているときのみ置き換える。
    func resolvedHistoryReading(userReading: String, inputKey: String, output: String) -> String {
        guard let canonical = azooKeyConverter.canonicalReading(for: inputKey, text: output),
              DatabaseManager.isReadingPrefix(userReading, of: canonical) else {
            return userReading
        }
        return canonical
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
        if state.isComposing && !skipHistory && !isPunctuation,
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
        invalidateMarkedTextSyncCache()
        client.insertText(text)
        state = CompositionState()
    }

    /// F6–F10 の変換確定。composingText が空なら false を返す。
    public mutating func handleFunctionKey(keyCode: UInt16, client: TextInputClient) -> Bool {
        guard state.isComposing else { return false }
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
    /// `.deleteSelected` は Shift+Delete（キー）専用。候補 UI の削除ボタンは `removeCandidate` 経路（`InputController.onDelete`）。
    /// 候補ウィンドウ更新は `InputController` のみ。
    public mutating func applyCandidateAction(_ action: CandidateAction, client: TextInputClient) {
        if case .deleteSelected = action,
           let text = candidateSession.selectedText {
            db.deleteHistory(output: text)
        }
        candidateSession.apply(action)
        syncMarkedText(client: client)
    }

    /// `commitText` 後など、次の `syncMarkedText` で dedup しないようキャッシュを破棄する。
    public mutating func invalidateMarkedTextSyncCache() {
        lastSyncedMarkedText = nil
        lastSyncedMarkedSelection = nil
    }

    /// 組成バッファと `candidateSession` の選択行から marked text を組み立てる。
    /// 通常は `applyCandidateAction` 経由。キー外（候補 UI 削除など）は `syncMarkedText` を直接呼ぶ。
    public mutating func syncMarkedText(client: TextInputClient) {
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
        let selection = NSRange(location: text.count, length: 0)
        if text == lastSyncedMarkedText, selection == lastSyncedMarkedSelection {
            return
        }
        lastSyncedMarkedText = text
        lastSyncedMarkedSelection = selection
        client.setMarkedText(text, selectionRange: selection)
    }

    public mutating func doBackspace(client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction) {
        let wasExplicitBeforeBackspace = candidateSession.isVisible && candidateSession.isExplicitlySelected
        let (handled, _) = state.backspace()
        if handled {
            sessionTracker.trackBackspaceContext(
                wasExplicit: wasExplicitBeforeBackspace,
                composedAfter: state.composedHiragana.count
            )
        }
        if !handled, let ctx = lastConfirmedContext {
            db.penalizeAll(
                input: ctx.input,
                output: ctx.output,
                fullReading: ctx.fullReading
            )
            lastConfirmedContext = nil
            lastKeyDownDidPenalize = true
        }
        guard handled else { return (false, .none) }
        // BS は読みを 1 戻す操作なので常に .whileTyping で rebuild する。
        // explicit を維持して rebuild すると selectedRow=0 で別語に強制スナップし
        // marked text がちらつく（例: 幹事 row=1 → BS → 間 row=0 が即 marked される）。
        // .whileTyping なら row=0 でも passive 扱いで markedText がひらがな組成のまま落ち着く。
        //
        // 打鍵側の `>=2` 閾値（`state.backspace()` が返す `needsRefresh`）は
        // 「2 char で初めて候補を出す」ためのもの。BS では「2 char で出ていた候補が
        // 1 BS で消える」体感を避けるため、composedHiragana が残っている限り rebuild する。
        // 1 char passive 候補は Space 経由でも到達可能な状態なので新規リスクはない。
        let shouldRefresh = !state.composedHiragana.isEmpty
        let action: CandidateAction = shouldRefresh ? buildCandidateListForTrigger(.whileTyping) : .dismiss
        return (true, action)
    }

    public mutating func doEscape(client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction) {
        let reading = state.finalizedText
        let wasExplicit = candidateSession.isExplicitlySelected
        guard state.reset() else { return (false, .none) }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        var anomaly: [String] = []
        if reading.count >= 3 { anomaly.append("escaped_long") }
        pendingSessionRecord = InputSessionRecord(
            ts: nowMs,
            keyCount: sessionTracker.keyCount,
            bsCount: sessionTracker.bsCount,
            compositionMs: sessionTracker.compositionMs(endMs: nowMs),
            reading: reading,
            committed: nil,
            candidateDepth: nil,
            wasExplicit: wasExplicit,
            scrollCount: sessionTracker.scrollCount,
            anomaly: anomaly,
            bsExplicitCount: sessionTracker.bsExplicitCount,
            bsShrunkToOneCount: sessionTracker.bsShrunkToOneCount
        )
        sessionTracker.reset()
        return (true, .dismiss)
    }
}
