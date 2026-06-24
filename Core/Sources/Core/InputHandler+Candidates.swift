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
        let userDictExact: [String]
        let userDictPrefix: [String]
        /// 履歴 1 件は exact / prefix どちらか or 両方の score を持つ（PLAN260624d）。
        let historyEntries: [HistoryEntry]
        let highHistoryCount: Int
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
        let highHistoryCount: Int
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

        // 1 output に exact / prefix 両方の score を集約（PLAN260624d）。
        var entriesByOutput: [String: HistoryEntry] = [:]
        var insertionOrder: [String] = []
        var exactCount = 0
        var prefixCount = 0
        for row in exactMatchScored where row.score >= CandidateScoreBuilder.historyScoreCutoff {
            if entriesByOutput[row.output] == nil {
                insertionOrder.append(row.output)
                exactCount += 1
            }
            entriesByOutput[row.output] = entriesByOutput[row.output]?.addingExact(row.score)
                ?? HistoryEntry(output: row.output, score: .exact(row.score))
        }
        for row in historyScored {
            guard row.score >= CandidateScoreBuilder.historyScoreCutoff,
                  !exactMatchHistoryOutputs.contains(row.output) else { continue }
            if entriesByOutput[row.output] == nil {
                insertionOrder.append(row.output)
                prefixCount += 1
            }
            entriesByOutput[row.output] = entriesByOutput[row.output]?.addingPrefix(row.score)
                ?? HistoryEntry(output: row.output, score: .prefix(row.score))
        }
        let historyEntries = insertionOrder.compactMap { entriesByOutput[$0] }
        return CheapCandidateSources(
            userDictRaw: userDictRaw,
            userDictExact: userDictExact,
            userDictPrefix: userDictPrefix,
            historyEntries: historyEntries,
            highHistoryCount: exactCount + prefixCount
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
            historyEntries: cheap.historyEntries,
            highHistoryCount: cheap.highHistoryCount
        )
    }

    private func hiraganaBonusKind(for reading: String) -> CandidateScoreBuilder.HiraganaBonusKind? {
        if hiraganaPreferredSet.contains(reading) { return .userSetting }
        if HiraganaPreferredBuiltins.words[reading] != nil { return .builtin }
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
           sources.highHistoryCount == 0,
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

        // 打鍵中: 組み込み助詞等は UI 非表示（concept 指針 1）。
        if trigger == .whileTyping, hiraganaBonusKind(for: h) == .builtin {
            #if DEBUG
            recordCandidateBuildDiagnostics(
                trigger: trigger,
                reading: h,
                outcome: .dismissedFunctionalWord,
                sources: sources,
                scored: [],
                scoredLayout: nil
            )
            #endif
            return .dismiss
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
            dateTimeCandidates: dateTimeCandidates
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
        let initialRow = 0
        guard !scoredLayout.candidates.isEmpty else {
            #if DEBUG
            recordCandidateBuildDiagnostics(
                trigger: trigger,
                reading: h,
                outcome: .dismissedEmpty,
                sources: sources,
                scored: scored,
                scoredLayout: scoredLayout,
                initialRow: initialRow
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
           initialRow < scoredLayout.candidates.count,
           Self.isBuiltinFunctionalWord(scoredLayout.candidates[initialRow]) {
            #if DEBUG
            recordCandidateBuildDiagnostics(
                trigger: trigger,
                reading: h,
                outcome: .dismissedFunctionalWord,
                sources: sources,
                scored: scored,
                scoredLayout: scoredLayout,
                initialRow: initialRow
            )
            #endif
            return .dismiss
        }

        if initialRow < scoredLayout.sources.count {
            switch scoredLayout.sources[initialRow] {
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
            scoredLayout: scoredLayout,
            initialRow: initialRow
        )
        #endif
        return .show(
            candidates: scoredLayout.candidates,
            initialRow: initialRow,
            fixedEnd: scoredLayout.fixedEnd,
            azooKeyApiOrder: apiOrder,
            initialIsExplicitlySelected: trigger == .explicit,
            candidateSources: scoredLayout.sources
        )
    }

    #if DEBUG
    private mutating func recordCandidateBuildDiagnostics(
        trigger: CandidateListTrigger,
        reading: String,
        outcome: CandidateBuildDiagnostics.Outcome,
        sources: CandidateListSources,
        scored: [ScoredCandidate],
        scoredLayout: CandidateScoredLayout.Result?,
        initialRow: Int? = nil
    ) {
        let resolvedInitialRow = initialRow ?? 0
        let initialText = scoredLayout.flatMap { layout in
            layout.candidates.indices.contains(resolvedInitialRow) ? layout.candidates[resolvedInitialRow] : nil
        }
        lastCandidateBuildDiagnostics = CandidateBuildDiagnostics(
            trigger: CandidateBuildDiagnosticsSupport.triggerLabel(trigger),
            reading: reading,
            outcome: outcome,
            hiraganaPreferred: hiraganaPreferredSet.contains(reading),
            hiraganaBuiltin: HiraganaPreferredBuiltins.words[reading] != nil,
            historyEntries: sources.historyEntries,
            userDictExact: sources.userDictExact,
            azooKeyCandidates: Array(sources.azooKeyCandidates.prefix(8)),
            azooKeyApiOrder: Array(sources.azooKeyApiOrder.prefix(8)),
            initialRow: resolvedInitialRow,
            initialText: initialText,
            fixedEnd: scoredLayout?.fixedEnd ?? 0,
            scoredSources: scored.prefix(8).map { CandidateBuildDiagnosticsSupport.scoredSourceLabel($0) },
            deferAzooKeyWhileTyping: deferAzooKeyWhileTyping
        )
    }
    #endif
}
