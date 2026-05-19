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

    static let punctuationMap: [String: String] = [:]

    static let bracketOptions: [String: [String]] = [
        "[": ["「", "【", "〔", "［", "〈", "《", "『"],
        "]": ["」", "】", "〕", "］", "〉", "》", "』"],
        "(": ["（", "〔", "｟"],
        ")": ["）", "〕", "｠"],
        "{": ["｛"],
        "}": ["｝"],
        "?": ["？", "?"],
        "!": ["！", "!"],
        "/": ["・", "／", "/"],
        ".": ["。", "．", "…", "‥", "・", "."],
        ",": ["、", "'", "•", ",", "○", ".", "…", "‥", "·"],
        "@": ["＠", "@"],
        "#": ["＃", "#"],
        "$": ["＄", "$"],
        "%": ["％", "%"],
        "^": ["＾", "^"],
        "&": ["＆", "&"],
        "*": ["＊", "*"],
        "<": ["＜", "<"],
        ">": ["＞", ">"],
        "_": ["＿", "_"],
        "+": ["＋", "±", "+"],
        "|": ["｜", "|"],
        ":": ["：", "；", ";", ":"],
        "\"": ["\u{201C}", "\u{201D}", "＂", "\""],
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
                    return (true, action)
                } else {
                    applyMarkedText(candidateText: nil, client: client)
                    if case .show(let candidates, let historyEnd, _, _, _) = action {
                        // ひらがな優先語は辞書候補の有無によらず initialRow を維持
                        if isHiraganaPreferred(state.composedHiragana) || candidates.count > historyEnd {
                            return (true, action)
                        }
                    }
                }
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
        highHistory = Array(highHistory.prefix(Self.maxHighHistoryCount))
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
        if let top1 = sources.zenzaiPromoted, insertedSet.insert(top1).inserted {
            candidates.insert(top1, at: fixedEnd)
            zenzaiTop1Count = 1
        }
        lastZenzaiRow = zenzaiTop1Count > 0 ? fixedEnd : nil
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

        // 長音符「ー」・小母音（ぁぃぅぇぉ）を含む読みは外来語・カタカナ語が期待される。
        let foreignMarkers: Set<Character> = ["ー", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ"]
        let hasForeignMarker = h.contains(where: { foreignMarkers.contains($0) })

        // 履歴/予測/Zenzai/特殊候補/ユーザー辞書がなく辞書候補がある場合、辞書先頭候補を row 0 に昇格
        // ただし外来語マーカーがある場合やひらがな/カタカナ固定候補がある場合は昇格しない
        let shouldPromoteFirstDict = fixedCount == 0
            && !hasForeignMarker
            && historyEnd == adjustedFixedEnd
            && zenzaiTop1Count == 0
            && userDictCount == 0
            && dateTimeCandidates.isEmpty
            && numberCandidates.isEmpty
            && candidates.count > adjustedFixedEnd
        if shouldPromoteFirstDict {
            let promoted = candidates.remove(at: adjustedFixedEnd)
            candidates.insert(promoted, at: 0)
        }

        let initialRow: Int
        if isHiraganaPreferred(h) {
            initialRow = candidates.firstIndex(of: h) ?? 0
        } else if hasForeignMarker, !katakanaInHistory, let katRow = candidates.firstIndex(of: katakana) {
            initialRow = katRow
        } else {
            initialRow = historyEnd > adjustedFixedEnd ? adjustedFixedEnd : 0
        }
        guard !candidates.isEmpty else { return .dismiss }

        return .show(candidates: candidates,
                     historyEnd: shouldPromoteFirstDict ? 0 : historyEnd,
                     initialRow: initialRow,
                     predictionEnd: shouldPromoteFirstDict ? 0 : predictionEnd,
                     fixedEnd: shouldPromoteFirstDict ? 0 : adjustedFixedEnd)
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
    private static let maxHighHistoryCount = 3

    func isHiraganaPreferred(_ h: String) -> Bool {
        hiraganaPreferredSet.contains(h)
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
