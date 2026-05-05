import AppKit

// MARK: - 候補リスト構築・候補表示中・通常入力
//
// `handle()` の主要分岐 4 つ：
//   - handleCandidateVisible  : 候補ウィンドウ表示中のキー
//   - handleBracketModeKey    : 括弧候補ウィンドウ表示中のキー
//   - handleNormalInput       : 通常の文字入力（ローマ字・Shift・記号）
//   - buildCandidateList      : 候補列の組み立て（履歴・bi-gram・azooKey 統合）
//   - doConfirmSelection      : Enter による候補確定

public extension InputHandler {

    // MARK: - z + キー 特殊文字マップ

    public static let zCharMap: [String: String] = [
        "-": "〜", "/": "・", ".": "…", ",": "、",
    ]
    public static let zArrowMap: [UInt16: String] = [
        KeyCode.rightArrow: "→", KeyCode.leftArrow: "←",
    ]

    // MARK: - 括弧候補マップ

    public static let punctuationMap: [String: String] = [",": "、", ".": "。"]

    public static let bracketOptions: [String: [String]] = [
        "[": ["「", "【", "〔", "［", "〈", "《", "『"],
        "]": ["」", "】", "〕", "］", "〉", "》", "』"],
        "(": ["（", "〔", "｟"],
        ")": ["）", "〕", "｠"],
        "{": ["｛"],
        "}": ["｝"],
    ]

    // MARK: - 括弧モード

    public mutating func handleBracketModeKey(
        keyCode: UInt16,
        characters: String?,
        baseCharacters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        let brackets = bracketCandidates!
        let selectedText = candidate.selectedText ?? brackets[0]

        switch keyCode {
        case KeyCode.escape, KeyCode.backspace:
            bracketCandidates = nil
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0))
            return (true, .dismiss)

        case KeyCode.enter:
            bracketCandidates = nil
            client.insertText(selectedText)
            return (true, .dismiss)

        case KeyCode.tab where modifiers.contains(.shift), KeyCode.upArrow:
            return (true, .selectPrev)

        case KeyCode.space, KeyCode.tab, KeyCode.downArrow:
            return (true, .selectNext)

        default:
            // 選択中の括弧を確定して、このキーは通常処理へ
            bracketCandidates = nil
            client.insertText(selectedText)
            return handleNormalInput(keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                                      modifiers: modifiers, wasExplicitlySelected: false,
                                      candidate: .hidden, client: client)
        }
    }

    @discardableResult
    public mutating func doConfirmSelection(candidate: CandidateContext, client: TextInputClient) -> CandidateAction {
        guard !state.composingText.isEmpty else { return .none }
        let inputKey = state.finalizedText
        let normalizedInput = inputKey.allSatisfy({ $0.isASCII }) ? inputKey.lowercased() : inputKey
        // Enter キーによる確定: 視覚的に選択中の候補をそのまま確定する
        if let selected = candidate.selectedText {
            let isDateTime = Self.generateDateTimeCandidates(for: normalizedInput).contains(selected)
            let isNumber = Self.generateNumberCandidates(for: normalizedInput).contains(selected)
            if !isDateTime && !isNumber { db.recordPrefixes(reading: normalizedInput, output: selected) }
            let conv = azooKeyConverter; let r = inputKey; let t = selected
            Task.detached(priority: .utility) { conv.commit(reading: r, text: t) }
            commitText(text: selected, skipHistory: isDateTime || isNumber, client: client)
        } else {
            commitComposition(client: client)
        }
        return suggestSuccessors()
    }

    public mutating func handleCandidateVisible(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        let isBackspace = keyCode == KeyCode.backspace || characters == "\u{08}"
        switch keyCode {
        case KeyCode.tab where modifiers.contains(.shift):
            return (true, .selectPrev)
        case KeyCode.space:
            if !state.composedHiragana.isEmpty {
                let action = enterSegmentMode()
                if state.isSegmentMode {
                    applySegmentMarkedText(client: client)
                } else {
                    applyMarkedText(candidateText: nil, client: client)
                }
                return (true, action)
            }
            return (true, .selectNext)
        case KeyCode.tab, KeyCode.downArrow:
            return (true, .selectNext)
        case KeyCode.upArrow:
            return (true, .selectPrev)
        case KeyCode.enter:
            return (true, doConfirmSelection(candidate: candidate, client: client))
        case KeyCode.escape:
            return doEscape(client: client)
        case KeyCode.rightArrow:
            commitComposition(client: client)
            return (true, suggestSuccessors())
        case KeyCode.backspace where modifiers.contains(.shift):
            let row = candidate.selectedRow
            if candidate.fixedEnd <= row && row < candidate.historyEnd { return (true, .deleteSelected) }
            return (true, .none)
        default:
            if isBackspace { return doBackspace(client: client) }
            return nil
        }
    }

    // handleNormalInput は入力種別ごとのプライベートハンドラへ振り分けるディスパッチテーブル。
    // 各ハンドラは nil（自分の担当外）または (consumed, action) を返す。
    public mutating func handleNormalInput(
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

    /// - Parameter autoShow: 文字入力中の自動表示（true）か Space など明示トリガー（false）か。
    ///   autoShow=true のとき履歴も辞書候補もなければ表示しない。
    public mutating func buildCandidateList(autoShow: Bool = false) -> CandidateAction {
        clearPendingScorerForDismiss()
        let h = state.composedHiragana
        let azooKeyCandidates: [String]
        let ctxFingerprint = leftSideContext
        if h.allSatisfy({ $0.isASCII }) {
            azooKeyCandidates = []
            lastAzooKeyInput = ""; lastAzooKeyContext = ""; lastAzooKeyResults = []
        } else if h == lastAzooKeyInput, ctxFingerprint == lastAzooKeyContext {
            azooKeyCandidates = lastAzooKeyResults
        } else {
            azooKeyCandidates = azooKeyConverter.requestCandidates(hiragana: h, leftSideContext: azooKeyLeftContext)
            lastAzooKeyInput = h; lastAzooKeyContext = ctxFingerprint; lastAzooKeyResults = azooKeyCandidates
        }
        let historyKey = (!h.isEmpty && h.allSatisfy({ $0.isASCII })) ? h.lowercased() : h
        let (userDictExact, userDictPrefix) = db.fetchUserDictCombined(reading: historyKey)
        let userDictRaw = Self.merged(userDictExact, userDictPrefix)
        let historyScored = db.fetchHistoryScoredMerged(reading: historyKey)
        var highHistory: [String] = []
        var lowHistory: [String] = []
        for row in historyScored {
            if row.score >= Self.historyRecencyScoreCutoff {
                highHistory.append(row.output)
            } else {
                lowHistory.append(row.output)
            }
        }
        let totalHistoryCount = historyScored.count
        let highHistoryCount = highHistory.count

        let bigramRaw = lastCommittedOutput.map { db.fetchBigram(prev: $0, reading: state.composedHiragana) } ?? []
        let trigramRaw: [String] = {
            guard let p1 = lastCommittedOutput, let p2 = prev2Output else { return [] }
            return db.fetchTrigram(prev2: p2, prev1: p1, reading: state.composedHiragana)
        }()
        let skipBigramRaw = mostRecentContentWords(n: 2).flatMap {
            db.fetchSkipBigram(prev: $0, reading: state.composedHiragana)
        }
        let predictRaw = Self.merged(trigramRaw, bigramRaw, skipBigramRaw)

        let historySeen = Set(historyScored.map(\.output))
        let azooKeyUniq = azooKeyCandidates.filter { !historySeen.contains($0) }
        var candidates = highHistory + azooKeyUniq
        let candidateSeen = historySeen.union(azooKeyUniq)
        let uniquePredictions = predictRaw.filter { !candidateSeen.contains($0) }
        candidates.insert(contentsOf: uniquePredictions, at: 0)
        let predictCount = uniquePredictions.count

        let numberCandidates = InputHandler.generateNumberCandidates(for: h)
        let dateTimeCandidates = InputHandler.generateDateTimeCandidates(for: h)
        if autoShow && totalHistoryCount == 0 && azooKeyCandidates.isEmpty && predictCount == 0
            && userDictRaw.isEmpty && dateTimeCandidates.isEmpty && numberCandidates.isEmpty {
            return .dismiss
        }

        let hiragana = state.composedHiragana
        let katakana = KanaUtils.hiraganaToKatakana(hiragana)

        // 履歴にひらがな・カタカナが含まれるかを確認する
        // 履歴にある場合 → 履歴エントリとして可視範囲に残す（固定位置に追加しない）
        // 履歴にない場合 → スクロール範囲外の固定位置に追加し、↑ キーで到達できるようにする
        // lowHistory はこの時点では candidates に未挿入のため集合で明示する。
        let hiraganaInHistory = candidates.prefix(predictCount + highHistoryCount).contains(hiragana)
            || lowHistory.contains(hiragana)
        let katakanaInHistory = candidates.prefix(predictCount + highHistoryCount).contains(katakana)
            || lowHistory.contains(katakana)

        let allCandidatesSeen = candidateSeen.union(uniquePredictions)
        var fixedCount = 0
        if !katakanaInHistory {
            if allCandidatesSeen.contains(katakana) { candidates.removeAll { $0 == katakana } }
            candidates.insert(katakana, at: 0)
            fixedCount += 1
        }
        // hiragana == katakana（非ひらがな文字）の場合は重複挿入しない
        if !hiraganaInHistory && hiragana != katakana {
            if allCandidatesSeen.contains(hiragana) { candidates.removeAll { $0 == hiragana } }
            candidates.insert(hiragana, at: 0)
            fixedCount += 1
        }

        // ユーザー辞書エントリをカナ固定の直後（initialRow = fixedCount）に挿入する。
        // 予測・履歴より高優先で表示し、Shift+Delete の誤削除から守るため fixedEnd で追跡する。
        var insertedSet = Set(candidates)
        let uniqueUserDict = userDictRaw.filter { insertedSet.insert($0).inserted }
        candidates.insert(contentsOf: uniqueUserDict, at: fixedCount)
        let userDictCount = uniqueUserDict.count
        let fixedEnd = fixedCount + userDictCount

        let historyEnd = fixedEnd + predictCount + highHistoryCount
        let predictionEnd = fixedEnd + predictCount
        let uniqueNumberCandidates = numberCandidates.filter { insertedSet.insert($0).inserted }
        let uniqueDateTimeCandidates = dateTimeCandidates.filter { insertedSet.insert($0).inserted }
        candidates.insert(contentsOf: uniqueNumberCandidates, at: historyEnd)
        candidates.insert(contentsOf: uniqueDateTimeCandidates, at: historyEnd + uniqueNumberCandidates.count)
        insertedSet = Set(candidates)
        let uniqueLowHistory = lowHistory.filter { insertedSet.insert($0).inserted }

        let numCount = uniqueNumberCandidates.count
        let dtCount = uniqueDateTimeCandidates.count
        let azooStart = historyEnd + numCount + dtCount
        let azooEnd = candidates.count
        var scorerGlobalIndices: [Int] = []
        if predictionEnd < historyEnd {
            for r in predictionEnd..<historyEnd {
                guard scorerGlobalIndices.count < 10 else { break }
                scorerGlobalIndices.append(r)
            }
        }
        if scorerGlobalIndices.count < 10, azooStart < azooEnd {
            for r in azooStart..<azooEnd {
                guard scorerGlobalIndices.count < 10 else { break }
                scorerGlobalIndices.append(r)
            }
        }

        candidates.append(contentsOf: uniqueLowHistory)
        // 助動詞・接続助詞等（ほぼひらがな表記のみ）は学習ゼロでもひらがなを初期選択する。
        // hiraganaInHistory の場合は固定位置にひらがながないため通常どおり fixedCount から。
        let preferHiragana = !hiraganaInHistory && Self.isHiraganaPreferred(h)
        // 履歴・辞書候補がある場合はその先頭を初期選択、固定候補のみなら先頭から表示
        let initialRow = (candidates.count > fixedCount && !preferHiragana) ? fixedCount : 0
        guard !candidates.isEmpty else { return .dismiss }

        pendingScorerGlobalIndices = scorerGlobalIndices
        pendingScorerStrings = scorerGlobalIndices.map { candidates[$0] }
        lastScorerEligible = Self.isComposedHiraganaEligibleForScorer(h)
            && !state.isSegmentMode
            && !isSuccessorMode
            && !isBracketMode
            && scorerGlobalIndices.count >= 2
        lastCandidateListAutoShow = autoShow

        return .show(candidates: candidates, historyEnd: historyEnd, initialRow: initialRow,
                     predictionEnd: predictionEnd, fixedEnd: fixedEnd)
    }

    private mutating func clearPendingScorerForDismiss() {
        pendingScorerGlobalIndices = []
        pendingScorerStrings = []
        lastScorerEligible = false
        lastCandidateListAutoShow = false
    }

    /// `InputController` のライフサイクル（サーバ再有効化など）用
    public mutating func resetScorerPending() {
        clearPendingScorerForDismiss()
    }

    /// スコアラー起動用: 2 文字以上かつひらがなのみ（記号・ASCII 混在の `buildCandidateList` 経路を除外）
    public static func isComposedHiraganaEligibleForScorer(_ s: String) -> Bool {
        guard s.count >= 2 else { return false }
        return s.unicodeScalars.allSatisfy { u in
            let v = u.value
            return (v >= 0x3041 && v <= 0x3096) || v == 0x309D || v == 0x309E
        }
    }

    /// composedHiragana が空で pendingRomaji が1文字のときに bi-gram を先読みして候補表示する。
    /// 候補が存在すれば isSuccessorMode = true を立てて返す。pendingRomaji は confirmSuccessor() で破棄される。
    public mutating func buildPendingCandidateList(pendingChar: String, client: TextInputClient) -> CandidateAction {
        resetScorerPending()
        guard let kanas = InputHandler.romajiToInitialKana[pendingChar],
              let prev = lastCommittedOutput else { return .dismiss }
        var seen = Set<String>()
        var candidates: [String] = []
        for kana in kanas {
            let fromTrigram: [String] = prev2Output.map {
                db.fetchTrigram(prev2: $0, prev1: prev, reading: kana)
            } ?? []
            let fromBigram = db.fetchBigram(prev: prev, reading: kana)
            let fromSkip: [String] = mostRecentContentWords(n: 2).flatMap {
                db.fetchSkipBigram(prev: $0, reading: kana)
            }
            for s in fromTrigram where seen.insert(s).inserted { candidates.append(s) }
            for s in fromBigram where seen.insert(s).inserted { candidates.append(s) }
            for s in fromSkip where seen.insert(s).inserted { candidates.append(s) }
        }
        guard !candidates.isEmpty else { return .dismiss }
        isSuccessorMode = true
        successorFirstChar = nil
        pendingSuccessorCandidates = []
        clearSuccessorLLMAuxiliaryState()
        client.setMarkedText(candidates[0], selectionRange: NSRange(location: candidates[0].count, length: 0))
        let fixedCandidates = kanas
        let allCandidates = Self.merged(fixedCandidates, candidates)
        return .show(candidates: allCandidates, historyEnd: 0, initialRow: fixedCandidates.count, predictionEnd: 0, fixedEnd: 0)
    }

    // MARK: - Private input handlers

    private mutating func flushPendingRomaji() {
        guard !state.pendingRomaji.isEmpty else { return }
        state.composedHiragana += RomajiConverter.forceFinalize(state.pendingRomaji)
        state.pendingRomaji = ""
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
            resetScorerPending()
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

    // MARK: - Utility

    /// これ未満の履歴スコアは AzooKey・数値・日時の後ろに回す（DB の `recencyExpr` と同じ尺度）。
    private static let historyRecencyScoreCutoff = 0.5

    /// 現代日本語でほぼひらがな表記のみが使われる語（助動詞・形式名詞・副助詞等）の末尾パターン。
    /// 学習ゼロ状態でもひらがな候補を初期選択にするために使用する。
    /// 静的プロパティとして一度だけコンパイルし、末尾マッチ（$）で判定する。
    private static let hiraganaPreferredRegex: NSRegularExpression = {
        let parts: [String] = [
            // て/で + 補助動詞（活用形をまとめて吸収）
            "[てで](いる|いた|いく|くる|おく|ある|しまう|しまった|しまって|みる|みた|ほしい" +
                "|います|いました|おきます|おきました|あります|ありました" +
                "|しまいます|しまいました|いきます|いきました|きます|きました" +
                "|みます|みました|くれます|くれました|あげます|あげました)",
            // 丁寧体助動詞・推量・勧誘
            "(ます|ました|ません|ませんでした|まして|ましょう|ませ)(が|ね|よ|か|けど|けれど)?",
            "(です|でした|でして|でしょう)(が|ね|よ|か|けど|けれど)?",
            // 接続助詞・接続詞
            "(な)?ので", "けれ?ど(も)?", "だから", "ながら", "つつ", "たり",
            // 形式名詞（公用文でひらがな表記が推奨されるもの）
            "(な|の)?(こと|もの|ところ|わけ|はず|つもり|ため|とおり|ほう)",
            // 推量・様態・比況・当為
            "らしい", "みたい(だ|に|な|です)?", "そう(だ|です|に|な)?",
            "よう(だ|です|に|な)?", "かもしれ(ない|ません)", "べき(だ|です)",
            // 副助詞
            "(く|ぐ)らい", "ばかり", "など", "まで", "だけ", "ほど",
        ]
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "(" + parts.joined(separator: "|") + ")$")
    }()

    public static func isHiraganaPreferred(_ h: String) -> Bool {
        let range = NSRange(h.startIndex..., in: h)
        return hiraganaPreferredRegex.firstMatch(in: h, range: range) != nil
    }

    /// 複数の配列を順序保持して重複排除しながら連結する（O(n) 版 flatten + deduplicate）。
    public static func merged(_ arrays: [String]...) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for arr in arrays {
            for s in arr where seen.insert(s).inserted {
                result.append(s)
            }
        }
        return result
    }
}
