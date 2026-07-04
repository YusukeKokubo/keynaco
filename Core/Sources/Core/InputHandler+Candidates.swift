import AppKit

// MARK: - 候補リスト構築
//
// 単一入口: `buildCandidateList(trigger:azooKey:)`（AzooKey 供給経路は `CandidateListAzooKeySupply`）。
// AzooKey 候補の重複呼び出し回避は `AzooKeyConverter.candidateCache`（read-through LRU）が担当。
// 候補表示中キーは InputHandler+CandidateInput.swift、括弧モードは +BracketMode.swift

extension InputHandler {

    // MARK: - 単一入口

    /// 候補列を組み立てる正本。`pendingAzooKeyReading` は `.peekOrDefer` で未キャッシュ時のみ非 `nil`。
    @discardableResult
    mutating func buildCandidateList(
        for trigger: CandidateListTrigger,
        azooKey supply: CandidateListAzooKeySupply = .fetchSync
    ) -> (action: CandidateAction, pendingAzooKeyReading: String?) {
        switch supply {
        case .fetchSync:
            let sources = collectCandidateSources(trigger: trigger)
            return (assembleCandidateList(from: sources, trigger: trigger), nil)

        case .peekOrDefer:
            let h = state.composedHiragana
            let needsAzooKey = !h.isEmpty && !h.allSatisfy(\.isASCII)
            let engineReading = Self.azooKeyReading(for: h)
            let peek = needsAzooKey
                ? azooKeyConverter.peekCachedCandidates(
                    hiragana: engineReading,
                    leftSideContext: leftContext.azooKeyValue,
                    richCandidates: true
                )
                : nil
            let peekRaw = peek?.candidates ?? []
            let pendingReading: String? = needsAzooKey && peek?.needsAsyncFetch != false ? h : nil
            let action = assembleFromSources(
                reading: h,
                azooKeyCandidates: peekRaw.texts,
                azooKeyApiOrder: peekRaw.texts,
                trigger: trigger
            )
            return (action, pendingReading)

        case .inject(let reading, let candidates):
            guard state.composedHiragana == reading else { return (.none, nil) }
            let action = assembleFromSources(
                reading: reading,
                azooKeyCandidates: candidates.texts,
                azooKeyApiOrder: candidates.texts,
                trigger: trigger
            )
            clearPendingAzooKeyReading()
            return (action, nil)
        }
    }

    /// 同期 fetch の糖衣。既存呼び出し元の大半はこちら。
    mutating func buildCandidateList(trigger: CandidateListTrigger = .explicit) -> CandidateAction {
        buildCandidateList(for: trigger, azooKey: .fetchSync).action
    }

    /// `deferAzooKeyWhileTyping` が有効な `.whileTyping` だけ AzooKey を遅延し `pendingAzooKeyReading` をセットする。
    mutating func buildCandidateListForTrigger(_ trigger: CandidateListTrigger) -> CandidateAction {
        let supply: CandidateListAzooKeySupply =
            (trigger == .whileTyping && deferAzooKeyWhileTyping) ? .peekOrDefer : .fetchSync
        let (action, pending) = buildCandidateList(for: trigger, azooKey: supply)
        notePendingAzooKeyReading(pending)
        return action
    }

    /// AzooKey を呼ばず安価ソースとキャッシュ済み辞書候補でリストを組み立てる。
    /// 非同期取得がまだ必要な読みだけ `pendingReading` に載せる（完全一致キャッシュヒット時は `nil`）。
    public mutating func buildCandidateListWithoutAzooKey(
        trigger: CandidateListTrigger
    ) -> (action: CandidateAction, pendingReading: String?) {
        let result = buildCandidateList(for: trigger, azooKey: .peekOrDefer)
        return (result.action, result.pendingAzooKeyReading)
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
        buildCandidateList(
            for: trigger,
            azooKey: .inject(reading: reading, candidates: azooKeyCandidates)
        ).action
    }

    private mutating func assembleFromSources(
        reading: String,
        azooKeyCandidates: [String],
        azooKeyApiOrder: [String],
        trigger: CandidateListTrigger
    ) -> CandidateAction {
        let sources = collectLocalCandidateSources(reading: reading)
            .withAzooKey(candidates: azooKeyCandidates, apiOrder: azooKeyApiOrder)
        return assembleCandidateList(from: sources, trigger: trigger)
    }

    private struct CandidateListSources {
        let h: String
        let azooKeyCandidates: [String]
        /// AzooKey API の返却順（Zenzai 込み）。Zenzai 順位ラベル表示等に使う。
        let azooKeyApiOrder: [String]
        let userDictRaw: [String]
        let userDictExact: [String]
        let userDictPrefix: [String]
        /// 履歴 1 件は exact / prefix どちらか or 両方の score を持つ（PLAN260624d）。
        let historyEntries: [HistoryEntry]

        func withAzooKey(candidates: [String], apiOrder: [String]) -> CandidateListSources {
            CandidateListSources(
                h: h,
                azooKeyCandidates: candidates,
                azooKeyApiOrder: apiOrder,
                userDictRaw: userDictRaw,
                userDictExact: userDictExact,
                userDictPrefix: userDictPrefix,
                historyEntries: historyEntries
            )
        }
    }

    private enum WhileTypingPreScoreDismiss {
        case emptySources
        case builtinReading
    }

    private struct ScoredCandidateBuild {
        let scored: [ScoredCandidate]
        let layout: CandidateScoredLayout.Result
        let apiOrder: [String]
    }

    private mutating func collectCandidateSources(
        trigger: CandidateListTrigger
    ) -> CandidateListSources {
        let h = state.composedHiragana
        let azooKeyCandidates = fetchAzooKeyCandidates(reading: h, trigger: trigger)
        return collectLocalCandidateSources(reading: h)
            .withAzooKey(candidates: azooKeyCandidates, apiOrder: azooKeyCandidates)
    }

    private mutating func collectLocalCandidateSources(reading: String) -> CandidateListSources {
        let isAscii = reading.allSatisfy({ $0.isASCII })
        let historyKey = (!reading.isEmpty && isAscii) ? reading.lowercased() : reading
        let (userDictExact, userDictPrefix) = db.fetchUserDictCombined(reading: historyKey)
        let userDictRaw = Self.merged(userDictExact, userDictPrefix)
        let historyScored = db.fetchHistoryScoredMerged(reading: historyKey)
        let exactMatchScored = db.fetchHistoryExactScored(reading: historyKey)
        let exactMatchHistoryOutputs = Set(exactMatchScored.map { $0.output })

        // 1 output に exact / prefix 両方の score を集約（PLAN260624d）。
        var entriesByOutput: [String: HistoryEntry] = [:]
        var insertionOrder: [String] = []
        for row in exactMatchScored where row.score >= CandidateScoreBuilder.historyScoreCutoff {
            if entriesByOutput[row.output] == nil {
                insertionOrder.append(row.output)
            }
            entriesByOutput[row.output] = entriesByOutput[row.output]?.addingExact(row.score)
                ?? HistoryEntry(output: row.output, score: .exact(row.score))
        }
        for row in historyScored {
            guard row.score >= CandidateScoreBuilder.historyScoreCutoff,
                  !exactMatchHistoryOutputs.contains(row.output) else { continue }
            if entriesByOutput[row.output] == nil {
                insertionOrder.append(row.output)
            }
            entriesByOutput[row.output] = entriesByOutput[row.output]?.addingPrefix(row.score)
                ?? HistoryEntry(output: row.output, score: .prefix(row.score))
        }
        let historyEntries = insertionOrder.compactMap { entriesByOutput[$0] }
        return CandidateListSources(
            h: reading,
            azooKeyCandidates: [],
            azooKeyApiOrder: [],
            userDictRaw: userDictRaw,
            userDictExact: userDictExact,
            userDictPrefix: userDictPrefix,
            historyEntries: historyEntries
        )
    }

    private mutating func fetchAzooKeyCandidates(
        reading: String,
        trigger: CandidateListTrigger
    ) -> [String] {
        guard !reading.allSatisfy({ $0.isASCII }) else { return [] }
        let engineReading = Self.azooKeyReading(for: reading)
        let richCandidates = trigger == .explicit
        let raw = azooKeyConverter.requestCandidates(
            hiragana: engineReading,
            leftSideContext: leftContext.azooKeyValue,
            richCandidates: richCandidates
        )
        return raw.texts
    }

    /// UserReading を AzooKey 向け EngineReading へ補完する。マッチしなければそのまま返す。
    public static func azooKeyReading(for userReading: String) -> String {
        NumericReadingExpander.engineReading(for: userReading) ?? userReading
    }

    private func hiraganaBonusKind(for reading: String) -> CandidateScoreBuilder.HiraganaBonusKind? {
        if hiraganaPreferredSet.contains(reading) { return .userSetting }
        if Self.isBuiltinFunctionalWord(reading) { return .builtin }
        return nil
    }

    /// `s` が組み込み助詞・助動詞等（concept 指針 1 でサジェストを抑制したい機能語）かを判定。
    /// reading の判定（pre-build dismiss）と top row text の判定（post-build dismiss）で
    /// 同じ predicate を共有する。
    private static func isBuiltinFunctionalWord(_ s: String) -> Bool {
        HiraganaPreferredBuiltins.words[s] != nil
    }

    private mutating func assembleCandidateList(
        from sources: CandidateListSources,
        trigger: CandidateListTrigger
    ) -> CandidateAction {
        let h = sources.h
        let numberCandidates = InputHandler.generateNumberCandidates(for: h)
        let dateTimeCandidates = InputHandler.generateDateTimeCandidates(for: h)

        if let preDismiss = whileTypingPreScoreDismissReason(
            sources: sources,
            trigger: trigger,
            numberCandidates: numberCandidates,
            dateTimeCandidates: dateTimeCandidates
        ) {
            return dismissWhileTyping(
                reading: h,
                sources: sources,
                preScore: preDismiss
            )
        }

        guard let built = buildScoredLayout(
            sources: sources,
            trigger: trigger,
            numberCandidates: numberCandidates,
            dateTimeCandidates: dateTimeCandidates
        ) else {
            #if DEBUG
            recordCandidateBuildDiagnostics(
                trigger: trigger,
                reading: h,
                outcome: .dismissedEmpty,
                sources: sources,
                scored: [],
                scoredLayout: nil
            )
            #endif
            return .dismiss
        }

        if trigger == .whileTyping,
           Self.isBuiltinFunctionalWord(built.layout.candidates[0]) {
            return dismissWhileTyping(
                reading: h,
                sources: sources,
                preScore: nil,
                scored: built.scored,
                scoredLayout: built.layout
            )
        }

        if built.layout.sources.indices.contains(0) {
            switch built.layout.sources[0] {
            case .hiraganaPreferred: lastInitialRowReason = .hiraganaPreferred
            case .hiraganaBuiltin: lastInitialRowReason = .hiraganaBuiltin
            default: lastInitialRowReason = .scoreOrder
            }
        } else {
            lastInitialRowReason = .scoreOrder
        }
        #if DEBUG
        recordCandidateBuildDiagnostics(
            trigger: trigger,
            reading: h,
            outcome: .shown,
            sources: sources,
            scored: built.scored,
            scoredLayout: built.layout
        )
        #endif
        return .show(
            candidates: built.layout.candidates,
            fixedEnd: built.layout.fixedEnd,
            azooKeyApiOrder: built.apiOrder,
            initialIsExplicitlySelected: trigger == .explicit,
            candidateSources: built.layout.sources
        )
    }

    private func whileTypingPreScoreDismissReason(
        sources: CandidateListSources,
        trigger: CandidateListTrigger,
        numberCandidates: [String],
        dateTimeCandidates: [String]
    ) -> WhileTypingPreScoreDismiss? {
        guard trigger == .whileTyping else { return nil }

        // 打鍵中で出すべき素材がゼロなら候補窓自体出さない（AzooKey 結果待ちの placeholder は廃止）。
        if sources.historyEntries.isEmpty,
           sources.azooKeyCandidates.isEmpty,
           sources.userDictRaw.isEmpty,
           dateTimeCandidates.isEmpty,
           numberCandidates.isEmpty,
           hiraganaBonusKind(for: sources.h) == nil {
            return .emptySources
        }

        // 打鍵中: 組み込み助詞等の reading は UI 非表示（concept 指針 1）。
        if Self.isBuiltinFunctionalWord(sources.h),
           !hiraganaPreferredSet.contains(sources.h) {
            return .builtinReading
        }

        return nil
    }

    private mutating func buildScoredLayout(
        sources: CandidateListSources,
        trigger: CandidateListTrigger,
        numberCandidates: [String],
        dateTimeCandidates: [String]
    ) -> ScoredCandidateBuild? {
        let zenzaiActive = azooKeyConverter.isZenzaiEnabled && leftContext.azooKeyValue != nil
        let apiOrder = zenzaiActive ? sources.azooKeyApiOrder : []
        let (historyEntries, userDictPrefix) = prefixFocusFilteredSources(
            reading: sources.h,
            trigger: trigger,
            historyEntries: sources.historyEntries,
            userDictPrefix: sources.userDictPrefix
        )
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: sources.h,
            hiraganaBonus: hiraganaBonusKind(for: sources.h),
            historyEntries: historyEntries,
            userDictExact: sources.userDictExact,
            userDictPrefix: userDictPrefix,
            azooKeyCandidates: sources.azooKeyCandidates,
            azooKeyApiOrder: apiOrder,
            numberCandidates: numberCandidates,
            dateTimeCandidates: dateTimeCandidates,
            trigger: trigger
        ))
        let scoredLayout = CandidateScoredLayout.assemble(CandidateScoredLayout.Input(
            scored: scored
        ))
        guard !scoredLayout.candidates.isEmpty else { return nil }
        return ScoredCandidateBuild(scored: scored, layout: scoredLayout, apiOrder: apiOrder)
    }

    /// whileTyping の機能語 dismiss（pre-score: reading / empty、post-score: row 0 text）。
    private mutating func dismissWhileTyping(
        reading: String,
        sources: CandidateListSources,
        preScore: WhileTypingPreScoreDismiss?,
        scored: [ScoredCandidate] = [],
        scoredLayout: CandidateScoredLayout.Result? = nil
    ) -> CandidateAction {
        #if DEBUG
        let outcome: CandidateBuildDiagnostics.Outcome = switch preScore {
        case .emptySources: .dismissedEmpty
        case .builtinReading, .none: .dismissedFunctionalWord
        }
        recordCandidateBuildDiagnostics(
            trigger: .whileTyping,
            reading: reading,
            outcome: outcome,
            sources: sources,
            scored: scored,
            scoredLayout: scoredLayout
        )
        #endif
        return .dismiss
    }

    #if DEBUG
    private mutating func recordCandidateBuildDiagnostics(
        trigger: CandidateListTrigger,
        reading: String,
        outcome: CandidateBuildDiagnostics.Outcome,
        sources: CandidateListSources,
        scored: [ScoredCandidate],
        scoredLayout: CandidateScoredLayout.Result?
    ) {
        let initialText = scoredLayout.flatMap { layout in
            layout.candidates.first
        }
        lastCandidateBuildDiagnostics = CandidateBuildDiagnostics(
            trigger: CandidateBuildDiagnosticsSupport.triggerLabel(trigger),
            reading: reading,
            outcome: outcome,
            hiraganaPreferred: hiraganaPreferredSet.contains(reading),
            hiraganaBuiltin: Self.isBuiltinFunctionalWord(reading),
            historyEntries: sources.historyEntries,
            userDictExact: sources.userDictExact,
            azooKeyCandidates: Array(sources.azooKeyCandidates.prefix(8)),
            azooKeyApiOrder: Array(sources.azooKeyApiOrder.prefix(8)),
            initialText: initialText,
            fixedEnd: scoredLayout?.fixedEnd ?? 0,
            scoredSources: scored.prefix(8).map { CandidateRowMetadata.scoredCandidateDiagnosticLabel($0) },
            deferAzooKeyWhileTyping: deferAzooKeyWhileTyping
        )
    }
    #endif

    /// `.whileTyping` のみ prefix focus モーラ閾値を適用。`.explicit` はそのまま返す。
    private func prefixFocusFilteredSources(
        reading: String,
        trigger: CandidateListTrigger,
        historyEntries: [HistoryEntry],
        userDictPrefix: [String]
    ) -> (historyEntries: [HistoryEntry], userDictPrefix: [String]) {
        guard trigger == .whileTyping else {
            return (historyEntries, userDictPrefix)
        }
        let accepts: (String) -> Bool = { output in
            PrefixFocusPolicy.acceptsPrefixFocus(
                reading: reading,
                output: output,
                db: db,
                azooKey: azooKeyConverter
            )
        }
        let filteredHistory = historyEntries.compactMap {
            $0.applyingPrefixFocusGate(acceptsPrefix: accepts)
        }
        let filteredUserDictPrefix = userDictPrefix.filter(accepts)
        return (filteredHistory, filteredUserDictPrefix)
    }
}
