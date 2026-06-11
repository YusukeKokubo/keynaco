import AppKit

// MARK: - 候補リスト構築
//
// `buildCandidateList` : 候補列の組み立て（履歴・AzooKey 統合）
// AzooKey 候補の重複呼び出し回避は `AzooKeyConverter.candidateCache`（read-through LRU）が担当。
// 候補表示中キーは InputHandler+CandidateInput.swift、括弧モードは +BracketMode.swift

extension InputHandler {

    // MARK: - buildCandidateList

    /// - Parameter trigger: `.whileTyping` は打鍵中のサジェスト、`.explicit` は Space（未表示時）等。
    mutating func buildCandidateList(trigger: CandidateListTrigger = .explicit) -> CandidateAction {
        buildCandidateListInternal(forReading: nil, trigger: trigger)
    }

    private mutating func buildCandidateListInternal(
        forReading reading: String?,
        trigger: CandidateListTrigger
    ) -> CandidateAction {
        let sources = collectCandidateSources(
            trigger: trigger,
            readingOverride: reading
        )
        return assembleCandidateList(from: sources, trigger: trigger)
    }

    /// 候補リスト中の Zenzai top-1 行を特定する。`assembleCandidateList` の副作用ではなく
    /// その結果から事後計算することで、リスト構築ロジックを純粋に保つ。
    private func resolveZenzaiRow(candidates: [String], zenzaiPromoted: String?) -> Int? {
        guard let top1 = zenzaiPromoted,
              let idx = candidates.firstIndex(of: top1) else { return nil }
        return idx
    }

    private struct CandidateListSources {
        let h: String
        let azooKeyCandidates: [String]
        let userDictRaw: [String]
        let highHistory: [String]
        let totalHistoryCount: Int
        let highHistoryCount: Int
        let zenzaiPromoted: String?
        let historyOutputSet: Set<String>
    }

    private mutating func collectCandidateSources(
        trigger: CandidateListTrigger,
        readingOverride: String? = nil
    ) -> CandidateListSources {
        let h = readingOverride ?? state.composedHiragana
        let azooKeyCandidates: [String]
        if h.allSatisfy({ $0.isASCII }) {
            azooKeyCandidates = []
        } else {
            let raw = azooKeyConverter.requestCandidates(
                hiragana: h,
                leftSideContext: azooKeyLeftContext,
                richCandidates: trigger == .explicit
            )
            azooKeyCandidates = raw.filter { !Self.isScriptMixed($0) }
        }
        let historyKey = (!h.isEmpty && h.allSatisfy({ $0.isASCII })) ? h.lowercased() : h
        let (userDictExact, userDictPrefix) = db.fetchUserDictCombined(reading: historyKey)
        let userDictRaw = Self.merged(userDictExact, userDictPrefix)
        let historyScored = db.fetchHistoryScoredMerged(reading: historyKey)
        var highHistory: [String] = []
        for row in historyScored where row.score >= Self.historyRecencyScoreCutoff {
            highHistory.append(row.output)
        }
        highHistory = Array(highHistory.prefix(Self.maxHighHistoryCount))
        let highHistoryCount = highHistory.count
        let totalHistoryCount = highHistoryCount

        let historyOutputSet = Set(historyScored.map(\.output))
        let zenzaiPromoted: String? = {
            guard azooKeyConverter.isZenzaiEnabled,
                  azooKeyLeftContext != nil,
                  let top1 = azooKeyCandidates.first else { return nil }
            return top1
        }()
        return CandidateListSources(
            h: h,
            azooKeyCandidates: azooKeyCandidates,
            userDictRaw: userDictRaw,
            highHistory: highHistory,
            totalHistoryCount: totalHistoryCount,
            highHistoryCount: highHistoryCount,
            zenzaiPromoted: zenzaiPromoted,
            historyOutputSet: historyOutputSet
        )
    }

    // MARK: - Fixed slot（hiraganaPreferred）

    /// これ未満の履歴スコアは候補に載せない（DB の `recencyExpr` と同じ尺度）。
    private static let historyRecencyScoreCutoff = 0.5
    /// 候補ヘッドの過剰膨張を抑える前方一致履歴の上限件数。
    private static let maxHighHistoryCount = 3

    private func resolveFixedSlot(
        reading: String,
        hiraganaInHistory: Bool
    ) -> CandidateFixedSlot {
        if isHiraganaPreferred(reading) {
            return hiraganaInHistory ? .none : .hiragana
        }
        return .none
    }

    /// 履歴・予測・ユーザー辞書・数値/日時がなく AzooKey のみのとき、読みのひらがなを先頭固定する。
    private func shouldAddDefaultFixedHiragana(
        trigger: CandidateListTrigger,
        fixedSlot: CandidateFixedSlot,
        hiraganaInHistory: Bool,
        sources: CandidateListSources,
        numberCandidates: [String],
        dateTimeCandidates: [String]
    ) -> Bool {
        trigger == .whileTyping
            && fixedSlot == .none
            && !hiraganaInHistory
            && sources.highHistoryCount == 0
            && sources.totalHistoryCount == 0
            && sources.userDictRaw.isEmpty
            && numberCandidates.isEmpty
            && dateTimeCandidates.isEmpty
    }

    /// ひらがなとカタカナが混在する表層（AzooKey が返す「きョ」等）を除外する。
    private static func isScriptMixed(_ text: String) -> Bool {
        var hasHiragana = false
        var hasKatakana = false
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x3041 && scalar.value <= 0x3096 { hasHiragana = true }
            if scalar.value >= 0x30A1 && scalar.value <= 0x30F6 { hasKatakana = true }
            if hasHiragana && hasKatakana { return true }
        }
        return false
    }

    private func assembleCandidateList(
        from sources: CandidateListSources,
        trigger: CandidateListTrigger
    ) -> CandidateAction {
        let h = sources.h
        let numberCandidates = InputHandler.generateNumberCandidates(for: h)
        let dateTimeCandidates = InputHandler.generateDateTimeCandidates(for: h)

        if trigger == .whileTyping && sources.totalHistoryCount == 0 && sources.azooKeyCandidates.isEmpty
            && sources.userDictRaw.isEmpty && dateTimeCandidates.isEmpty && numberCandidates.isEmpty {
            return .dismiss
        }

        let hiragana = state.composedHiragana
        let katakana = KanaUtils.hiraganaToKatakana(hiragana)
        let hiraganaInHistory = sources.highHistory.contains(hiragana)
        let fixedSlot = resolveFixedSlot(reading: h, hiraganaInHistory: hiraganaInHistory)

        let addsDefaultFixedHiragana = shouldAddDefaultFixedHiragana(
            trigger: trigger,
            fixedSlot: fixedSlot,
            hiraganaInHistory: hiraganaInHistory,
            sources: sources,
            numberCandidates: numberCandidates,
            dateTimeCandidates: dateTimeCandidates
        )
        let built = CandidateSectionBuilder.build(CandidateSectionBuildInput(
            reading: h,
            hiragana: hiragana,
            katakana: katakana,
            azooKeyCandidates: sources.azooKeyCandidates,
            userDictRaw: sources.userDictRaw,
            highHistory: sources.highHistory,
            historyOutputSet: sources.historyOutputSet,
            zenzaiPromoted: sources.zenzaiPromoted,
            fixedSlot: fixedSlot,
            addsDefaultFixedHiragana: addsDefaultFixedHiragana,
            numberCandidates: numberCandidates,
            dateTimeCandidates: dateTimeCandidates
        ))
        let layout = CandidateLayout(
            sections: built.sections,
            sectionOrder: built.sectionOrder,
            initialRowPolicy: InitialRowPolicyResolver.resolve(InitialRowPolicyInput(
                reading: h,
                fixedSlot: fixedSlot,
                hiraganaInHistory: hiraganaInHistory,
                addsDefaultFixedHiragana: addsDefaultFixedHiragana,
                zenzaiPromoted: sources.zenzaiPromoted
            ))
        )
        guard !layout.candidates.isEmpty else { return .dismiss }

        // 打鍵中のみ: 第一候補が機能語（助詞・助動詞等）ならサジェスト UI を出さない。
        // 明示トリガ（Space・未表示時）は候補を出す。
        if trigger == .whileTyping,
           layout.initialRow < layout.candidates.count,
           HiraganaPreferredBuiltins.words[layout.candidates[layout.initialRow]] != nil {
            return .dismiss
        }

        let zRow = resolveZenzaiRow(
            candidates: layout.candidates,
            zenzaiPromoted: sources.zenzaiPromoted
        )
        return .show(
            candidates: layout.candidates,
            historyEnd: layout.historyEnd,
            initialRow: layout.initialRow,
            fixedEnd: layout.fixedEnd,
            zenzaiRow: zRow,
            initialIsExplicitlySelected: trigger == .explicit
        )
    }
}
