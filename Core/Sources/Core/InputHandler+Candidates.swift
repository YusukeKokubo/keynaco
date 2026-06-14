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

    /// AzooKey を呼ばず安価ソースとキャッシュ済み辞書候補でリストを組み立てる。
    /// 非同期取得がまだ必要な読みだけ `pendingReading` に載せる（完全一致キャッシュヒット時は `nil`）。
    public mutating func buildCandidateListWithoutAzooKey(
        trigger: CandidateListTrigger
    ) -> (action: CandidateAction, pendingReading: String?) {
        let h = state.composedHiragana
        let needsAzooKey = !h.isEmpty && !h.allSatisfy(\.isASCII)
        let peek = needsAzooKey
            ? azooKeyConverter.peekCachedCandidates(
                hiragana: h,
                leftSideContext: leftContext.azooKeyValue,
                richCandidates: true
            )
            : nil
        let peekRaw = peek?.candidates ?? []
        let azooKeyCandidates = sortAzooKeyCandidates(
            peekRaw,
            reading: h,
            richCandidates: true
        )
        let pendingReading: String? = needsAzooKey && peek?.needsAsyncFetch != false ? h : nil
        let cheap = collectCheapCandidateSources(readingOverride: h)
        let sources = makeCandidateListSources(
            h: h,
            cheap: cheap,
            azooKeyCandidates: azooKeyCandidates,
            azooKeyApiOrder: peekRaw
        )
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
        let sorted = sortAzooKeyCandidates(
            filtered,
            reading: reading,
            richCandidates: true
        )
        let cheap = collectCheapCandidateSources(readingOverride: reading)
        let sources = makeCandidateListSources(
            h: reading,
            cheap: cheap,
            azooKeyCandidates: sorted,
            azooKeyApiOrder: filtered
        )
        let action = assembleCandidateList(from: sources, trigger: trigger)
        clearPendingAzooKeyReading()
        return action
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

    private struct CheapCandidateSources {
        let userDictRaw: [String]
        /// `userDictRaw` のうち読み完全一致だけを抜き出した配列。初期選択行の判定に使う。
        let userDictExact: [String]
        /// 読み前方一致のユーザー辞書（初期フォーカス判定用）。
        let userDictPrefix: [String]
        let exactMatchHighHistory: [String]
        let highHistory: [String]
        let highHistoryCount: Int
        let historyOutputSet: Set<String>
        let exactMatchHistoryOutputs: Set<String>
    }

    private struct CandidateListSources {
        let h: String
        let azooKeyCandidates: [String]
        /// LCID ソート前の AzooKey API 順序。Zenzai 順位表示用。
        let azooKeyApiOrder: [String]
        let userDictRaw: [String]
        /// 読み完全一致のユーザー辞書（初期選択行判定用）。
        let userDictExact: [String]
        /// 読み前方一致のユーザー辞書（初期フォーカス判定用）。
        let userDictPrefix: [String]
        let exactMatchHighHistory: [String]
        let highHistory: [String]
        let highHistoryCount: Int
        let historyOutputSet: Set<String>
        let exactMatchHistoryOutputs: Set<String>
    }

    private mutating func collectCandidateSources(
        trigger: CandidateListTrigger,
        readingOverride: String? = nil
    ) -> CandidateListSources {
        let h = readingOverride ?? state.composedHiragana
        let cheap = collectCheapCandidateSources(readingOverride: readingOverride)
        let fetch = fetchAzooKeyCandidates(reading: h, trigger: trigger)
        return makeCandidateListSources(
            h: h,
            cheap: cheap,
            azooKeyCandidates: fetch.sorted,
            azooKeyApiOrder: fetch.apiOrder
        )
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
            userDictExact: userDictExact,
            userDictPrefix: userDictPrefix,
            exactMatchHighHistory: exactMatchHighHistory,
            highHistory: highHistory,
            highHistoryCount: exactMatchHighHistory.count + highHistory.count,
            historyOutputSet: historyOutputSet,
            exactMatchHistoryOutputs: exactMatchHistoryOutputs
        )
    }

    private struct AzooKeyFetch {
        let sorted: [String]
        /// LCID ソート前の filtered 配列。各候補の AzooKey 内部順位を Zenzai 表示用に残す。
        let apiOrder: [String]
    }

    private mutating func fetchAzooKeyCandidates(
        reading: String,
        trigger: CandidateListTrigger
    ) -> AzooKeyFetch {
        guard !reading.allSatisfy({ $0.isASCII }) else { return AzooKeyFetch(sorted: [], apiOrder: []) }
        let richCandidates = trigger == .explicit
        let raw = azooKeyConverter.requestCandidates(
            hiragana: reading,
            leftSideContext: leftContext.azooKeyValue,
            richCandidates: richCandidates
        )
        let filtered = raw.filter { !KanaUtils.isScriptMixed($0) }
        let sorted = sortAzooKeyCandidates(filtered, reading: reading, richCandidates: richCandidates)
        return AzooKeyFetch(sorted: sorted, apiOrder: filtered)
    }

    private func sortAzooKeyCandidates(
        _ candidates: [String],
        reading: String,
        richCandidates: Bool
    ) -> [String] {
        guard candidates.count > 1 else { return candidates }
        let lcidByText = azooKeyConverter.primaryLcidByText(
            hiragana: reading,
            leftSideContext: leftContext.azooKeyValue,
            richCandidates: richCandidates
        )
        return Self.sortAzooKeyCandidatesByLcidRank(candidates, lcidByText: lcidByText)
    }

    /// AzooKey 辞書セクション内の lcid 安定ソート。`lcidByText` が空なら入力順を維持。
    static func sortAzooKeyCandidatesByLcidRank(
        _ candidates: [String],
        lcidByText: [String: Int]
    ) -> [String] {
        guard candidates.count > 1, !lcidByText.isEmpty else { return candidates }
        return candidates.enumerated().sorted { lhs, rhs in
            let leftRank = LcidRank.from(lcid: lcidByText[lhs.element])
            let rightRank = LcidRank.from(lcid: lcidByText[rhs.element])
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func makeCandidateListSources(
        h: String,
        cheap: CheapCandidateSources,
        azooKeyCandidates: [String],
        azooKeyApiOrder: [String] = []
    ) -> CandidateListSources {
        CandidateListSources(
            h: h,
            azooKeyCandidates: azooKeyCandidates,
            azooKeyApiOrder: azooKeyApiOrder,
            userDictRaw: cheap.userDictRaw,
            userDictExact: cheap.userDictExact,
            userDictPrefix: cheap.userDictPrefix,
            exactMatchHighHistory: cheap.exactMatchHighHistory,
            highHistory: cheap.highHistory,
            highHistoryCount: cheap.highHistoryCount,
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

    private mutating func assembleCandidateList(
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
            #if DEBUG
            recordCandidateBuildDiagnostics(
                trigger: trigger,
                reading: h,
                outcome: .dismissedEmpty,
                fixedSlot: .none,
                hiraganaInHistory: false,
                addsDefaultFixedHiragana: false,
                sources: sources,
                built: nil,
                policy: .afterFixed,
                layout: nil
            )
            #endif
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
            azooKeyApiOrder: sources.azooKeyApiOrder,
            userDictRaw: sources.userDictRaw,
            exactMatchHighHistory: sources.exactMatchHighHistory,
            highHistory: sources.highHistory,
            historyOutputSet: sources.historyOutputSet,
            exactMatchHistoryOutputs: sources.exactMatchHistoryOutputs,
            fixedSlot: fixedSlot,
            addsDefaultFixedHiragana: addsDefaultFixedHiragana,
            numberCandidates: numberCandidates,
            dateTimeCandidates: dateTimeCandidates
        ))
        let previewLayout = CandidateLayout(
            sections: built.sections,
            sectionOrder: built.sectionOrder,
            initialRowPolicy: .afterFixed
        )
        let prefixFocusRank = { (output: String) in
            InitialRowPolicyResolver.rankForPrefixFocus(
                output: output,
                db: db,
                azooKey: azooKeyConverter,
                readingHint: h
            )
        }
        let prefixFocusCandidate = trigger == .whileTyping
            ? InitialRowPolicyResolver.prefixFocusCandidate(
                reading: h,
                prefixHistory: sources.highHistory,
                userDictPrefix: sources.userDictPrefix,
                rankForOutput: prefixFocusRank
            )
            : nil
        let policy = InitialRowPolicyResolver.resolve(InitialRowPolicyInput(
            reading: h,
            fixedSlot: fixedSlot,
            hiraganaInHistory: hiraganaInHistory,
            addsDefaultFixedHiragana: addsDefaultFixedHiragana,
            exactMatchHighHistory: sources.exactMatchHighHistory,
            userDictExact: sources.userDictExact,
            prefixFocusCandidate: prefixFocusCandidate,
            azooKeyCandidates: sources.azooKeyCandidates,
            candidateList: previewLayout.candidates
        ))
        let layout = CandidateLayout(
            sections: built.sections,
            sectionOrder: built.sectionOrder,
            initialRowPolicy: policy
        )
        let computedRow = layout.initialRow
        let exactMatchHistorySet = Set(sources.exactMatchHighHistory)
        let whileTypingRow = trigger == .whileTyping
            ? InitialRowPolicyResolver.whileTypingInitialRow(
                candidates: layout.candidates,
                fixedEnd: layout.fixedEnd,
                historyEnd: layout.historyEnd,
                computedRow: computedRow,
                reading: h,
                exactMatchHistory: exactMatchHistorySet,
                rankForOutput: prefixFocusRank
            )
            : computedRow
        guard whileTypingRow != nil || trigger != .whileTyping else {
            #if DEBUG
            recordCandidateBuildDiagnostics(
                trigger: trigger,
                reading: h,
                outcome: .dismissedEmpty,
                fixedSlot: fixedSlot,
                hiraganaInHistory: hiraganaInHistory,
                addsDefaultFixedHiragana: addsDefaultFixedHiragana,
                sources: sources,
                built: built,
                policy: policy,
                layout: layout
            )
            #endif
            return .dismiss
        }
        let initialRow = CandidateLayout.adjustedInitialRow(
            candidates: layout.candidates,
            fixedEnd: layout.fixedEnd,
            computedRow: whileTypingRow ?? computedRow,
            appliesDefaultFixedHiragana: addsDefaultFixedHiragana
        )
        guard !layout.candidates.isEmpty else {
            #if DEBUG
            recordCandidateBuildDiagnostics(
                trigger: trigger,
                reading: h,
                outcome: .dismissedEmpty,
                fixedSlot: fixedSlot,
                hiraganaInHistory: hiraganaInHistory,
                addsDefaultFixedHiragana: addsDefaultFixedHiragana,
                sources: sources,
                built: built,
                policy: policy,
                layout: layout
            )
            #endif
            return .dismiss
        }

        // 打鍵中のみ: 第一候補が機能語（助詞・助動詞等）ならサジェスト UI を出さない。
        // 明示トリガ（Space・未表示時）は候補を出す。
        if trigger == .whileTyping,
           initialRow < layout.candidates.count,
           HiraganaPreferredBuiltins.words[layout.candidates[initialRow]] != nil {
            #if DEBUG
            recordCandidateBuildDiagnostics(
                trigger: trigger,
                reading: h,
                outcome: .dismissedFunctionalWord,
                fixedSlot: fixedSlot,
                hiraganaInHistory: hiraganaInHistory,
                addsDefaultFixedHiragana: addsDefaultFixedHiragana,
                sources: sources,
                built: built,
                policy: policy,
                layout: layout
            )
            #endif
            return .dismiss
        }

        let zenzaiActive = azooKeyConverter.isZenzaiEnabled && leftContext.azooKeyValue != nil
        let apiOrder = zenzaiActive ? sources.azooKeyApiOrder : []
        #if DEBUG
        recordCandidateBuildDiagnostics(
            trigger: trigger,
            reading: h,
            outcome: .shown,
            fixedSlot: fixedSlot,
            hiraganaInHistory: hiraganaInHistory,
            addsDefaultFixedHiragana: addsDefaultFixedHiragana,
            sources: sources,
            built: built,
            policy: policy,
            layout: layout
        )
        #endif
        return .show(
            candidates: layout.candidates,
            historyEnd: layout.historyEnd,
            initialRow: initialRow,
            fixedEnd: layout.fixedEnd,
            azooKeyApiOrder: apiOrder,
            initialIsExplicitlySelected: trigger == .explicit
        )
    }

    #if DEBUG
    private mutating func recordCandidateBuildDiagnostics(
        trigger: CandidateListTrigger,
        reading: String,
        outcome: CandidateBuildDiagnostics.Outcome,
        fixedSlot: CandidateFixedSlot,
        hiraganaInHistory: Bool,
        addsDefaultFixedHiragana: Bool,
        sources: CandidateListSources,
        built: CandidateSectionBuildResult?,
        policy: InitialRowPolicy,
        layout: CandidateLayout?
    ) {
        let initialRow = layout?.initialRow ?? 0
        let initialText = layout.flatMap { l in
            l.candidates.indices.contains(initialRow) ? l.candidates[initialRow] : nil
        }
        lastCandidateBuildDiagnostics = CandidateBuildDiagnostics(
            trigger: CandidateBuildDiagnosticsSupport.triggerLabel(trigger),
            reading: reading,
            outcome: outcome,
            fixedSlot: CandidateBuildDiagnosticsSupport.fixedSlotLabel(fixedSlot),
            hiraganaPreferred: hiraganaPreferredSet.contains(reading),
            hiraganaBuiltin: HiraganaPreferredBuiltins.words[reading] != nil,
            hiraganaInHistory: hiraganaInHistory,
            addsDefaultFixedHiragana: addsDefaultFixedHiragana,
            exactMatchHighHistory: sources.exactMatchHighHistory,
            highHistory: sources.highHistory,
            userDictExact: sources.userDictExact,
            azooKeyCandidates: Array(sources.azooKeyCandidates.prefix(8)),
            azooKeyApiOrder: Array(sources.azooKeyApiOrder.prefix(8)),
            initialRowPolicy: CandidateBuildDiagnosticsSupport.policyLabel(policy),
            initialRow: initialRow,
            initialText: initialText,
            fixedEnd: layout?.fixedEnd ?? 0,
            historyEnd: layout?.historyEnd ?? 0,
            sections: built.map { CandidateBuildDiagnosticsSupport.sectionLabels($0.sections) } ?? [],
            deferAzooKeyWhileTyping: deferAzooKeyWhileTyping
        )
    }
    #endif
}
