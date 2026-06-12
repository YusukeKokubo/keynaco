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

    /// AzooKey 非同期取得待ちの仮候補（かなのみ・履歴/辞書セクションなし）か。
    /// Phase 3.5 で打鍵中に出すプレースホルダ。Space が `.selectNext` になると辞書に届かないため明示変換へ昇格する。
    func isAzooKeyPendingKanaPlaceholder(_ candidate: CandidateContext) -> Bool {
        guard deferAzooKeyWhileTyping,
              candidate.isVisible,
              !candidate.isExplicitlySelected,
              candidate.historyEnd == candidate.fixedEnd else { return false }
        let cands = candidateSession.candidates
        guard !cands.isEmpty else { return false }
        return !cands.contains(where: KanaUtils.containsCJKIdeograph)
    }

    /// `deferAzooKeyWhileTyping` が有効な `.whileTyping` だけ AzooKey を遅延し `pendingAzooKeyReading` をセットする。
    mutating func buildCandidateListForTrigger(_ trigger: CandidateListTrigger) -> CandidateAction {
        if trigger == .whileTyping, deferAzooKeyWhileTyping {
            let (action, pending) = buildCandidateListWithoutAzooKey(trigger: trigger)
            notePendingAzooKeyReading(pending)
            return action
        }
        return buildCandidateList(trigger: trigger)
    }

    /// AzooKey を呼ばず安価ソースだけで候補を組み立てる。
    /// AzooKey が必要な読み（非 ASCII かつ非空）なら `pendingReading` に読みを返す。
    public mutating func buildCandidateListWithoutAzooKey(
        trigger: CandidateListTrigger
    ) -> (action: CandidateAction, pendingReading: String?) {
        let h = state.composedHiragana
        let pendingReading: String? = (h.isEmpty || h.allSatisfy(\.isASCII)) ? nil : h
        let cheap = collectCheapCandidateSources(readingOverride: h)
        let sources = makeCandidateListSources(h: h, cheap: cheap, azooKeyCandidates: [])
        let action = assembleCandidateList(from: sources, trigger: trigger)
        return (action, pendingReading)
    }

    /// 非同期 AzooKey 結果の注入。`state.composedHiragana == reading` のときのみ有効。
    ///
    /// InputController は AzooKey タスク生成時に `trigger` をキャプチャして渡すこと
    ///（コールバック時のデフォルト `.whileTyping` に頼らない）。
    public mutating func rebuildCandidateList(
        reading: String,
        azooKeyCandidates: [String],
        trigger: CandidateListTrigger = .whileTyping
    ) -> CandidateAction {
        guard state.composedHiragana == reading else { return .none }
        let filtered = azooKeyCandidates.filter { !KanaUtils.isScriptMixed($0) }
        let cheap = collectCheapCandidateSources(readingOverride: reading)
        let sources = makeCandidateListSources(h: reading, cheap: cheap, azooKeyCandidates: filtered)
        return assembleCandidateList(from: sources, trigger: trigger)
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

    private struct CheapCandidateSources {
        let userDictRaw: [String]
        let exactMatchHighHistory: [String]
        let highHistory: [String]
        let highHistoryCount: Int
        let historyOutputSet: Set<String>
        let exactMatchHistoryOutputs: Set<String>
    }

    private struct CandidateListSources {
        let h: String
        let azooKeyCandidates: [String]
        let userDictRaw: [String]
        let exactMatchHighHistory: [String]
        let highHistory: [String]
        let highHistoryCount: Int
        let zenzaiPromoted: String?
        let historyOutputSet: Set<String>
        let exactMatchHistoryOutputs: Set<String>
    }

    private mutating func collectCandidateSources(
        trigger: CandidateListTrigger,
        readingOverride: String? = nil
    ) -> CandidateListSources {
        let h = readingOverride ?? state.composedHiragana
        let cheap = collectCheapCandidateSources(readingOverride: readingOverride)
        let azooKeyCandidates = fetchAzooKeyCandidates(reading: h, trigger: trigger)
        return makeCandidateListSources(h: h, cheap: cheap, azooKeyCandidates: azooKeyCandidates)
    }

    private mutating func collectCheapCandidateSources(
        readingOverride: String? = nil
    ) -> CheapCandidateSources {
        let h = readingOverride ?? state.composedHiragana
        let isAscii = h.allSatisfy({ $0.isASCII })
        let historyKey = (!h.isEmpty && isAscii) ? h.lowercased() : h
        let (userDictExact, userDictPrefix) = db.fetchUserDictCombined(reading: historyKey)
        let userDictRaw = Self.merged(userDictExact, userDictPrefix)
        let historyScored = db.fetchHistoryScoredMerged(reading: historyKey)
        let exactMatchHistoryOutputs = Set(db.fetchHistoryExact(reading: historyKey))
        var exactMatchHighHistory: [String] = []
        var highHistory: [String] = []
        var historyOutputSet = Set<String>()
        var seenExact = Set<String>()
        var seenOther = Set<String>()
        for row in historyScored {
            historyOutputSet.insert(row.output)
            if row.score >= Self.historyRecencyScoreCutoff,
               exactMatchHistoryOutputs.contains(row.output),
               seenExact.insert(row.output).inserted {
                exactMatchHighHistory.append(row.output)
            }
        }
        for row in historyScored {
            guard row.score >= Self.historyRecencyScoreCutoff,
                  !exactMatchHistoryOutputs.contains(row.output),
                  highHistory.count < Self.maxHighHistoryCount,
                  seenOther.insert(row.output).inserted else { continue }
            highHistory.append(row.output)
        }
        return CheapCandidateSources(
            userDictRaw: userDictRaw,
            exactMatchHighHistory: exactMatchHighHistory,
            highHistory: highHistory,
            highHistoryCount: exactMatchHighHistory.count + highHistory.count,
            historyOutputSet: historyOutputSet,
            exactMatchHistoryOutputs: exactMatchHistoryOutputs
        )
    }

    private mutating func fetchAzooKeyCandidates(
        reading: String,
        trigger: CandidateListTrigger
    ) -> [String] {
        guard !reading.allSatisfy({ $0.isASCII }) else { return [] }
        let raw = azooKeyConverter.requestCandidates(
            hiragana: reading,
            leftSideContext: leftContext.azooKeyValue,
            richCandidates: trigger == .explicit
        )
        return raw.filter { !KanaUtils.isScriptMixed($0) }
    }

    private func makeCandidateListSources(
        h: String,
        cheap: CheapCandidateSources,
        azooKeyCandidates: [String]
    ) -> CandidateListSources {
        let zenzaiPromoted: String? = {
            guard azooKeyConverter.isZenzaiEnabled,
                  leftContext.azooKeyValue != nil,
                  let top1 = azooKeyCandidates.first else { return nil }
            return top1
        }()
        return CandidateListSources(
            h: h,
            azooKeyCandidates: azooKeyCandidates,
            userDictRaw: cheap.userDictRaw,
            exactMatchHighHistory: cheap.exactMatchHighHistory,
            highHistory: cheap.highHistory,
            highHistoryCount: cheap.highHistoryCount,
            zenzaiPromoted: zenzaiPromoted,
            historyOutputSet: cheap.historyOutputSet,
            exactMatchHistoryOutputs: cheap.exactMatchHistoryOutputs
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
            && sources.userDictRaw.isEmpty
            && numberCandidates.isEmpty
            && dateTimeCandidates.isEmpty
    }

    private func assembleCandidateList(
        from sources: CandidateListSources,
        trigger: CandidateListTrigger
    ) -> CandidateAction {
        let h = sources.h
        let numberCandidates = InputHandler.generateNumberCandidates(for: h)
        let dateTimeCandidates = InputHandler.generateDateTimeCandidates(for: h)

        // defer 有効時は AzooKey 到着前でも読みのひらがな/カタカナを即時出す（空ウィンドウ充填ではない）。
        if trigger == .whileTyping,
           !deferAzooKeyWhileTyping,
           sources.highHistoryCount == 0,
           sources.azooKeyCandidates.isEmpty,
           sources.userDictRaw.isEmpty,
           dateTimeCandidates.isEmpty,
           numberCandidates.isEmpty {
            return .dismiss
        }

        let hiragana = state.composedHiragana
        let katakana = KanaUtils.hiraganaToKatakana(hiragana)
        let hiraganaInHistory = sources.exactMatchHighHistory.contains(hiragana)
            || sources.highHistory.contains(hiragana)
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
            exactMatchHighHistory: sources.exactMatchHighHistory,
            highHistory: sources.highHistory,
            historyOutputSet: sources.historyOutputSet,
            exactMatchHistoryOutputs: sources.exactMatchHistoryOutputs,
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
                zenzaiPromoted: sources.zenzaiPromoted,
                exactMatchHighHistory: sources.exactMatchHighHistory
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
