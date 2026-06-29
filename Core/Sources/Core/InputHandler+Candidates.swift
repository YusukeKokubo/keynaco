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
        assembleCandidateList(from: collectCandidateSources(trigger: trigger), trigger: trigger)
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
        let action = assembleFromSources(
            reading: h,
            azooKeyCandidates: peekRaw.texts,
            azooKeyApiOrder: peekRaw.texts,
            trigger: trigger
        )
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
        let action = assembleFromSources(
            reading: reading,
            azooKeyCandidates: azooKeyCandidates.texts,
            azooKeyApiOrder: azooKeyCandidates.texts,
            trigger: trigger
        )
        clearPendingAzooKeyReading()
        return action
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
        let richCandidates = trigger == .explicit
        let raw = azooKeyConverter.requestCandidates(
            hiragana: reading,
            leftSideContext: leftContext.azooKeyValue,
            richCandidates: richCandidates
        )
        return raw.texts
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

        // 打鍵中で出すべき素材がゼロなら候補窓自体出さない（AzooKey 結果待ちの placeholder は廃止）。
        if trigger == .whileTyping,
           sources.historyEntries.isEmpty,
           sources.azooKeyCandidates.isEmpty,
           sources.userDictRaw.isEmpty,
           dateTimeCandidates.isEmpty,
           numberCandidates.isEmpty,
           hiraganaBonusKind(for: h) == nil {
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

        // 打鍵中: 組み込み助詞等の reading は UI 非表示（concept 指針 1）。
        if trigger == .whileTyping,
           Self.isBuiltinFunctionalWord(h),
           !hiraganaPreferredSet.contains(h) {
            return dismissBuiltinFunctionalWordWhileTyping(
                reading: h,
                sources: sources
            )
        }

        let zenzaiActive = azooKeyConverter.isZenzaiEnabled && leftContext.azooKeyValue != nil
        let apiOrder = zenzaiActive ? sources.azooKeyApiOrder : []
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: h,
            hiraganaBonus: hiraganaBonusKind(for: h),
            historyEntries: sources.historyEntries,
            userDictExact: sources.userDictExact,
            userDictPrefix: sources.userDictPrefix,
            azooKeyCandidates: sources.azooKeyCandidates,
            azooKeyApiOrder: apiOrder,
            numberCandidates: numberCandidates,
            dateTimeCandidates: dateTimeCandidates,
            trigger: trigger
        ))
        let scoredLayout = CandidateScoredLayout.assemble(CandidateScoredLayout.Input(
            scored: scored
        ))
        // 初期行は score 順先頭で確定（PLAN260624b/c）。
        // hiraganaPreferred (userSetting/builtin) の reading は scoreBuilder の
        // hiraganaBonus(100/80) で大半が row 0 に来る。`は`/`と`/`で`/`か` のような
        // 短い reading + 超高 score の prefix history (例: `は` → `話` SUM 138.7)
        // のケースでは score 順で漢字側が row 0 になるが、助詞入力は whileTyping の
        // builtin dismiss 経由 (Space 不要、Enter で marked text 直接確定) で完結
        // するため、Space 経由の selectedRow が変わっても実動線に影響なし。
        guard !scoredLayout.candidates.isEmpty else {
            #if DEBUG
            recordCandidateBuildDiagnostics(
                trigger: trigger,
                reading: h,
                outcome: .dismissedEmpty,
                sources: sources,
                scored: scored,
                scoredLayout: scoredLayout
            )
            #endif
            return .dismiss
        }

        // 打鍵中のみ: 第一候補（行 0）の text が機能語ならサジェスト UI を出さない。
        // pre-build 側（reading が機能語）は assemble 前段で dismiss 済み。
        // こちらが拾うのは「reading は機能語でないが row 0 の text がたまたま機能語」の経路:
        //   - history/userDict/azooKey で機能語 text が row 0 に押し上げられたケース
        //   - userSetting hiraganaPreferred で機能語以外の reading が機能語 text を生むケース
        if trigger == .whileTyping,
           Self.isBuiltinFunctionalWord(scoredLayout.candidates[0]) {
            return dismissBuiltinFunctionalWordWhileTyping(
                reading: h,
                sources: sources,
                scored: scored,
                scoredLayout: scoredLayout
            )
        }

        if scoredLayout.sources.indices.contains(0) {
            switch scoredLayout.sources[0] {
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
            scored: scored,
            scoredLayout: scoredLayout
        )
        #endif
        return .show(
            candidates: scoredLayout.candidates,
            fixedEnd: scoredLayout.fixedEnd,
            azooKeyApiOrder: apiOrder,
            initialIsExplicitlySelected: trigger == .explicit,
            candidateSources: scoredLayout.sources
        )
    }

    /// whileTyping の機能語 dismiss（pre-build: reading / post-build: row 0 text）。
    private mutating func dismissBuiltinFunctionalWordWhileTyping(
        reading: String,
        sources: CandidateListSources,
        scored: [ScoredCandidate] = [],
        scoredLayout: CandidateScoredLayout.Result? = nil
    ) -> CandidateAction {
        #if DEBUG
        recordCandidateBuildDiagnostics(
            trigger: .whileTyping,
            reading: reading,
            outcome: .dismissedFunctionalWord,
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
            scoredSources: scored.prefix(8).map { CandidateBuildDiagnosticsSupport.scoredSourceLabel($0) },
            deferAzooKeyWhileTyping: deferAzooKeyWhileTyping
        )
    }
    #endif
}
