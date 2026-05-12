import AppKit

// MARK: - 候補リスト構築・候補表示中・通常入力
//
// `handle()` の主要分岐 4 つ：
//   - handleCandidateVisible  : 候補ウィンドウ表示中のキー
//   - handleBracketModeKey    : 括弧候補ウィンドウ表示中のキー
//   - handleNormalInput       : 通常の文字入力（InputHandler+NormalInput.swift）
//   - buildCandidateList      : 候補列の組み立て（履歴・bi-gram・azooKey 統合）
//   - doConfirmSelection      : Enter による候補確定

public extension InputHandler {

    // MARK: - z + キー 特殊文字マップ

    static let zCharMap: [String: String] = [
        "-": "〜", "/": "・", ".": "…", ",": "、",
    ]
    static let zArrowMap: [UInt16: String] = [
        KeyCode.rightArrow: "→", KeyCode.leftArrow: "←",
    ]

    // MARK: - 括弧候補マップ

    static let punctuationMap: [String: String] = [",": "、", ".": "。"]

    static let bracketOptions: [String: [String]] = [
        "[": ["「", "【", "〔", "［", "〈", "《", "『"],
        "]": ["」", "】", "〕", "］", "〉", "》", "』"],
        "(": ["（", "〔", "｟"],
        ")": ["）", "〕", "｠"],
        "{": ["｛"],
        "}": ["｝"],
        "?": ["？", "?"],
        "!": ["！", "!"],
    ]

    // MARK: - 括弧モード

    mutating func handleBracketModeKey(
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
    mutating func doConfirmSelection(candidate: CandidateContext, client: TextInputClient) -> CandidateAction {
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

    mutating func handleCandidateVisible(
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

    // MARK: - buildCandidateList

    /// - Parameter autoShow: 文字入力中の自動表示（true）か Space など明示トリガー（false）か。
    ///   autoShow=true のとき履歴も辞書候補もなければ表示しない。
    mutating func buildCandidateList(autoShow: Bool = false) -> CandidateAction {
        let sources = collectCandidateSources(autoShow: autoShow)
        return assembleCandidateList(from: sources, autoShow: autoShow)
    }

    private struct CandidateListSources {
        let h: String
        let azooKeyCandidates: [String]
        let userDictRaw: [String]
        let highHistory: [String]
        let lowHistory: [String]
        let totalHistoryCount: Int
        let highHistoryCount: Int
        let uniquePredictions: [String]
        let predictCount: Int
        let zenzaiPromoted: String?
        let azooKeyUniq: [String]
        let historySeen: Set<String>
    }

    private mutating func collectCandidateSources(autoShow: Bool) -> CandidateListSources {
        let h = state.composedHiragana
        let azooKeyCandidates: [String]
        let ctxFingerprint = leftSideContext
        if h.allSatisfy({ $0.isASCII }) {
            azooKeyCandidates = []
            lastAzooKeyInput = ""; lastAzooKeyContext = ""; lastAzooKeyResults = []
        } else if h == lastAzooKeyInput, ctxFingerprint == lastAzooKeyContext, autoShow {
            azooKeyCandidates = lastAzooKeyResults
        } else {
            azooKeyCandidates = azooKeyConverter.requestCandidates(hiragana: h, leftSideContext: azooKeyLeftContext, richCandidates: !autoShow)
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
        let zenzaiPromoted: String? = {
            guard azooKeyConverter.isZenzaiEnabled,
                  azooKeyLeftContext != nil,
                  let top1 = azooKeyCandidates.first else { return nil }
            return top1
        }()
        let azooKeyUniq = azooKeyCandidates.filter {
            !historySeen.contains($0) && $0 != zenzaiPromoted
        }
        let candidateSeen = historySeen.union(Set(azooKeyCandidates))
        let uniquePredictions = predictRaw.filter { !candidateSeen.contains($0) }
        let predictCount = uniquePredictions.count

        return CandidateListSources(
            h: h,
            azooKeyCandidates: azooKeyCandidates,
            userDictRaw: userDictRaw,
            highHistory: highHistory,
            lowHistory: lowHistory,
            totalHistoryCount: totalHistoryCount,
            highHistoryCount: highHistoryCount,
            uniquePredictions: uniquePredictions,
            predictCount: predictCount,
            zenzaiPromoted: zenzaiPromoted,
            azooKeyUniq: azooKeyUniq,
            historySeen: historySeen
        )
    }

    private mutating func assembleCandidateList(from sources: CandidateListSources, autoShow: Bool) -> CandidateAction {
        let h = sources.h
        let numberCandidates = InputHandler.generateNumberCandidates(for: h)
        let dateTimeCandidates = InputHandler.generateDateTimeCandidates(for: h)
        if autoShow && sources.totalHistoryCount == 0 && sources.azooKeyCandidates.isEmpty && sources.predictCount == 0
            && sources.userDictRaw.isEmpty && dateTimeCandidates.isEmpty && numberCandidates.isEmpty {
            return .dismiss
        }

        var candidates = sources.highHistory + sources.azooKeyUniq
        candidates.insert(contentsOf: sources.uniquePredictions, at: 0)
        let predictCount = sources.predictCount
        let highHistoryCount = sources.highHistoryCount
        let lowHistory = sources.lowHistory

        let hiragana = state.composedHiragana
        let katakana = KanaUtils.hiraganaToKatakana(hiragana)

        let hiraganaInHistory = candidates.prefix(predictCount + highHistoryCount).contains(hiragana)
            || lowHistory.contains(hiragana)
        let katakanaInHistory = candidates.prefix(predictCount + highHistoryCount).contains(katakana)
            || lowHistory.contains(katakana)

        let candidateSeen = sources.historySeen.union(Set(sources.azooKeyCandidates))
        let allCandidatesSeen = candidateSeen.union(Set(sources.uniquePredictions))
        var fixedCount = 0
        if !katakanaInHistory {
            if allCandidatesSeen.contains(katakana) { candidates.removeAll { $0 == katakana } }
            candidates.insert(katakana, at: 0)
            fixedCount += 1
        }
        if !hiraganaInHistory && hiragana != katakana {
            if allCandidatesSeen.contains(hiragana) { candidates.removeAll { $0 == hiragana } }
            candidates.insert(hiragana, at: 0)
            fixedCount += 1
        }

        var insertedSet = Set(candidates)
        let uniqueUserDict = sources.userDictRaw.filter { insertedSet.insert($0).inserted }
        candidates.insert(contentsOf: uniqueUserDict, at: fixedCount)
        let userDictCount = uniqueUserDict.count
        let fixedEnd = fixedCount + userDictCount

        var zenzaiTop1Count = 0
        if let top1 = sources.zenzaiPromoted, !uniqueUserDict.contains(top1) {
            candidates.insert(top1, at: fixedEnd)
            zenzaiTop1Count = 1
            insertedSet.insert(top1)
        }
        let adjustedFixedEnd = fixedEnd + zenzaiTop1Count

        let historyEnd = adjustedFixedEnd + predictCount + highHistoryCount
        let predictionEnd = adjustedFixedEnd + predictCount

        appendSpecialCandidates(
            &candidates,
            insertedSet: &insertedSet,
            historyEnd: historyEnd,
            numberCandidates: numberCandidates,
            dateTimeCandidates: dateTimeCandidates,
            lowHistory: lowHistory
        )

        let preferHiragana = !hiraganaInHistory && Self.isHiraganaPreferred(h)
        let initialRow = (candidates.count > fixedCount && !preferHiragana) ? fixedCount : 0
        guard !candidates.isEmpty else { return .dismiss }

        return .show(candidates: candidates, historyEnd: historyEnd, initialRow: initialRow,
                     predictionEnd: predictionEnd, fixedEnd: adjustedFixedEnd)
    }

    private mutating func appendSpecialCandidates(
        _ candidates: inout [String],
        insertedSet: inout Set<String>,
        historyEnd: Int,
        numberCandidates: [String],
        dateTimeCandidates: [String],
        lowHistory: [String]
    ) {
        let uniqueNumberCandidates = numberCandidates.filter { insertedSet.insert($0).inserted }
        let uniqueDateTimeCandidates = dateTimeCandidates.filter { insertedSet.insert($0).inserted }
        candidates.insert(contentsOf: uniqueNumberCandidates, at: historyEnd)
        candidates.insert(contentsOf: uniqueDateTimeCandidates, at: historyEnd + uniqueNumberCandidates.count)
        insertedSet = Set(candidates)
        let uniqueLowHistory = lowHistory.filter { insertedSet.insert($0).inserted }
        candidates.append(contentsOf: uniqueLowHistory)
    }

    /// composedHiragana が空で pendingRomaji が1文字のときに bi-gram を先読みして候補表示する。
    /// 候補が存在すれば isSuccessorMode = true を立てて返す。pendingRomaji は confirmSuccessor() で破棄される。
    mutating func buildPendingCandidateList(pendingChar: String, client: TextInputClient) -> CandidateAction {
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
            "(な)?ので", "けれ?ど(も)?", "だから", "ながら", "つつ", "たり", "[てで]も",
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

    static func isHiraganaPreferred(_ h: String) -> Bool {
        let range = NSRange(h.startIndex..., in: h)
        return hiraganaPreferredRegex.firstMatch(in: h, range: range) != nil
    }

    /// 複数の配列を順序保持して重複排除しながら連結する（O(n) 版 flatten + deduplicate）。
    static func merged(_ arrays: [String]...) -> [String] {
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
