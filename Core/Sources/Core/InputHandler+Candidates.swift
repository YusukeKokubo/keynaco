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
        let pendingReading: String? = needsAzooKey && peek?.needsAsyncFetch != false ? h : nil
        let cheap = collectCheapCandidateSources(readingOverride: h)
        let sources = makeCandidateListSources(
            h: h,
            cheap: cheap,
            azooKeyCandidates: peekRaw.texts,
            azooKeyApiOrder: peekRaw.texts
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
        azooKeyCandidates: [AzooKeyCandidate],
        trigger: CandidateListTrigger = .whileTyping
    ) -> CandidateAction {
        guard state.composedHiragana == reading else { return .none }
        let cheap = collectCheapCandidateSources(readingOverride: reading)
        let sources = makeCandidateListSources(
            h: reading,
            cheap: cheap,
            azooKeyCandidates: azooKeyCandidates.texts,
            azooKeyApiOrder: azooKeyCandidates.texts
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
        /// AzooKey API の返却順（Zenzai 込み）。Zenzai 順位ラベル表示と `exactMatchHighHistory` の並べ替えに使う。
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
        let azooKeyCandidates = fetchAzooKeyCandidates(reading: h, trigger: trigger)
        return makeCandidateListSources(
            h: h,
            cheap: cheap,
            azooKeyCandidates: azooKeyCandidates,
            azooKeyApiOrder: azooKeyCandidates
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
        let exactMatchScored = db.fetchHistoryExactScored(reading: historyKey)
        let exactMatchHistoryOutputs = Set(exactMatchScored.map { $0.output })
        var exactMatchHighHistory: [String] = []
        var highHistory: [String] = []
        var historyOutputSet = Set<String>()
        var seenExact = Set<String>()
        var seenOther = Set<String>()
        for row in exactMatchScored {
            if row.score >= Self.historyRecencyScoreCutoff,
               seenExact.insert(row.output).inserted {
                exactMatchHighHistory.append(row.output)
            }
        }
        for row in historyScored {
            historyOutputSet.insert(row.output)
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

    private mutating func fetchAzooKeyCandidates(
        reading: String,
        trigger: CandidateListTrigger
    ) -> [String] {
        guard !reading.allSatisfy({ $0.isASCII }) else { return [] }
        let richCandidates = trigger == .explicit
        let raw = azooKeyConverter.requestCandidates(
            hiragana: reading,
            leftSideContext: leftContext.azooKeyValue,
            richCandidates: richCandidates
        )
        return raw.texts
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

    private func resolveFixedSlot(reading: String) -> CandidateFixedSlot {
        isHiraganaPreferred(reading) ? .hiragana : .none
    }

    private mutating func assembleCandidateList(
        from sources: CandidateListSources,
        trigger: CandidateListTrigger
    ) -> CandidateAction {
        let h = sources.h
        let numberCandidates = InputHandler.generateNumberCandidates(for: h)
        let dateTimeCandidates = InputHandler.generateDateTimeCandidates(for: h)

        let hiragana = state.composedHiragana
        let fixedSlot = resolveFixedSlot(reading: h)

        // 打鍵中で出すべき素材がゼロなら候補窓自体出さない（AzooKey 結果待ちの placeholder は廃止）。
        // hiraganaPreferred 経路（fixedSlot=.hiragana）は明示的な意図なので維持する。
        if trigger == .whileTyping,
           fixedSlot == .none,
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
                sources: sources,
                built: nil,
                policy: .afterFixed,
                layout: nil
            )
            #endif
            return .dismiss
        }

        let built = CandidateSectionBuilder.build(CandidateSectionBuildInput(
            reading: h,
            hiragana: hiragana,
            azooKeyCandidates: sources.azooKeyCandidates,
            azooKeyApiOrder: sources.azooKeyApiOrder,
            userDictRaw: sources.userDictRaw,
            exactMatchHighHistory: sources.exactMatchHighHistory,
            highHistory: sources.highHistory,
            historyOutputSet: sources.historyOutputSet,
            exactMatchHistoryOutputs: sources.exactMatchHistoryOutputs,
            fixedSlot: fixedSlot,
            numberCandidates: numberCandidates,
            dateTimeCandidates: dateTimeCandidates
        ))
        let previewLayout = CandidateLayout(
            sections: built.sections,
            sectionOrder: built.sectionOrder,
            initialRowPolicy: .afterFixed
        )
        let prefixFocusRank = { (output: String) in
            InitialRowPolicyResolver.rankForPrefixFocus(output: output, db: db)
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
                sources: sources,
                built: built,
                policy: policy,
                layout: layout
            )
            #endif
            return .dismiss
        }
        let initialRow = whileTypingRow ?? computedRow
        guard !layout.candidates.isEmpty else {
            #if DEBUG
            recordCandidateBuildDiagnostics(
                trigger: trigger,
                reading: h,
                outcome: .dismissedEmpty,
                fixedSlot: fixedSlot,
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
        if !sources.exactMatchHighHistory.isEmpty {
            lastInitialRowReason = "exactMatchHistory"
        } else if !sources.userDictExact.isEmpty {
            lastInitialRowReason = "userDictExact"
        } else if prefixFocusCandidate != nil {
            lastInitialRowReason = "prefixFocus"
        } else if !sources.azooKeyCandidates.isEmpty {
            lastInitialRowReason = "azooKey"
        } else {
            lastInitialRowReason = "afterFixed"
        }
        #if DEBUG
        recordCandidateBuildDiagnostics(
            trigger: trigger,
            reading: h,
            outcome: .shown,
            fixedSlot: fixedSlot,
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
