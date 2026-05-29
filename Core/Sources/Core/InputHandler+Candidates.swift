import AppKit

// MARK: - 候補リスト構築
//
// `buildCandidateList` : 候補列の組み立て（履歴・bi-gram・azooKey 統合）
// 括弧モード・候補表示中は InputHandler+BracketMode.swift

public extension InputHandler {

    // MARK: - buildCandidateList

    /// - Parameter autoShow: 文字入力中の自動表示（true）か Space など明示トリガー（false）か。
    ///   autoShow=true のとき履歴も辞書候補もなければ表示しない。
    mutating func buildCandidateList(autoShow: Bool = false) -> CandidateAction {
        let sources = collectCandidateSources(autoShow: autoShow)
        let action = assembleCandidateList(from: sources, autoShow: autoShow)
        lastZenzaiRow = resolveZenzaiRow(action: action, zenzaiPromoted: sources.zenzaiPromoted)
        return action
    }

    /// 候補リスト中の Zenzai top-1 行を特定する。`assembleCandidateList` の副作用ではなく
    /// その結果から事後計算することで、リスト構築ロジックを純粋に保つ。
    private func resolveZenzaiRow(action: CandidateAction, zenzaiPromoted: String?) -> Int? {
        guard let top1 = zenzaiPromoted,
              case .show(let candidates, _, _, _, _) = action,
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
            let raw = azooKeyConverter.requestCandidates(hiragana: h, leftSideContext: azooKeyLeftContext, richCandidates: !autoShow)
            azooKeyCandidates = raw.filter { !Self.isScriptMixed($0) }
            lastAzooKeyInput = h; lastAzooKeyContext = ctxFingerprint; lastAzooKeyResults = azooKeyCandidates
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
        let uniquePredictions: [String] = []
        let predictCount = 0

        return CandidateListSources(
            h: h,
            azooKeyCandidates: azooKeyCandidates,
            userDictRaw: userDictRaw,
            highHistory: highHistory,
            totalHistoryCount: totalHistoryCount,
            highHistoryCount: highHistoryCount,
            uniquePredictions: uniquePredictions,
            predictCount: predictCount,
            zenzaiPromoted: zenzaiPromoted,
            azooKeyUniq: azooKeyUniq,
            historySeen: historySeen
        )
    }

    // MARK: - Fixed slot（hiraganaPreferred）

    /// これ未満の履歴スコアは候補に載せない（DB の `recencyExpr` と同じ尺度）。
    private static let historyRecencyScoreCutoff = 0.5
    /// 候補ヘッドの過剰膨張を抑える前方一致履歴の上限件数。
    private static let maxHighHistoryCount = 3

    /// 先頭固定枠の種別。
    private enum FixedSlot {
        case none
        case hiragana
    }

    private func resolveFixedSlot(
        reading: String,
        hiraganaInHistory: Bool
    ) -> FixedSlot {
        if isHiraganaPreferred(reading) {
            return hiraganaInHistory ? .none : .hiragana
        }
        return .none
    }

    private func resolveInitialRowPolicy(
        sources: CandidateListSources,
        fixedSlot: FixedSlot,
        hiraganaInHistory: Bool,
        addsDefaultFixedHiragana: Bool
    ) -> InitialRowPolicy {
        switch fixedSlot {
        case .hiragana:
            return .firstMatching(state.composedHiragana)
        case .none:
            if addsDefaultFixedHiragana {
                // Zenzai が先頭に来る場合は row 0 を初期選択にする
                if sources.zenzaiPromoted != nil { return .atZero }
                return .firstMatching(state.composedHiragana)
            }
            // 履歴があっても Zenzai がプロモートされとれば row 0 を初期選択にする
            if sources.zenzaiPromoted != nil { return .atZero }
            return .afterFixed
        }
    }

    /// 履歴・予測・ユーザー辞書・数値/日時がなく AzooKey のみのとき、読みのひらがなを先頭固定する。
    private func shouldAddDefaultFixedHiragana(
        autoShow: Bool,
        fixedSlot: FixedSlot,
        hiraganaInHistory: Bool,
        sources: CandidateListSources,
        numberCandidates: [String],
        dateTimeCandidates: [String]
    ) -> Bool {
        autoShow
            && fixedSlot == .none
            && !hiraganaInHistory
            && sources.predictCount == 0
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

    private func buildSections(
        from sources: CandidateListSources,
        fixedSlot: FixedSlot,
        hiraganaInHistory: Bool,
        addsDefaultFixedHiragana: Bool,
        numberCandidates: [String],
        dateTimeCandidates: [String]
    ) -> [CandidateSection] {
        let hiragana = state.composedHiragana
        let katakana = KanaUtils.hiraganaToKatakana(hiragana)

        let basePool = sources.uniquePredictions + sources.highHistory + sources.azooKeyUniq
        let allCandidatesSeen = sources.historySeen
            .union(Set(sources.azooKeyCandidates))
            .union(Set(sources.uniquePredictions))

        var sections: [CandidateSection] = []
        var insertedSet = Set(basePool)

        switch fixedSlot {
        case .hiragana:
            if allCandidatesSeen.contains(hiragana) { insertedSet.remove(hiragana) }
            sections.append(CandidateSection(kind: .fixedHiragana, items: [hiragana]))
            insertedSet.insert(hiragana)
        case .none:
            if addsDefaultFixedHiragana {
                if allCandidatesSeen.contains(hiragana) { insertedSet.remove(hiragana) }
                sections.append(CandidateSection(kind: .fixedHiragana, items: [hiragana]))
                insertedSet.insert(hiragana)
            }
        }

        let uniqueUserDict = sources.userDictRaw.filter { insertedSet.insert($0).inserted }
        if !uniqueUserDict.isEmpty {
            sections.append(CandidateSection(kind: .userDict, items: uniqueUserDict))
        }

        if let top1 = sources.zenzaiPromoted, insertedSet.insert(top1).inserted {
            sections.append(CandidateSection(kind: .zenzaiTop1, items: [top1]))
        }

        if !sources.uniquePredictions.isEmpty {
            sections.append(CandidateSection(kind: .prediction, items: sources.uniquePredictions))
        }
        if !sources.highHistory.isEmpty {
            sections.append(CandidateSection(kind: .highHistory, items: sources.highHistory))
        }

        let uniqueNumberCandidates = numberCandidates.filter { insertedSet.insert($0).inserted }
        if !uniqueNumberCandidates.isEmpty {
            sections.append(CandidateSection(kind: .number, items: uniqueNumberCandidates))
        }
        let uniqueDateTimeCandidates = dateTimeCandidates.filter { insertedSet.insert($0).inserted }
        if !uniqueDateTimeCandidates.isEmpty {
            sections.append(CandidateSection(kind: .dateTime, items: uniqueDateTimeCandidates))
        }

        let azooKeyItems = sources.azooKeyUniq.filter { candidate in
            guard addsDefaultFixedHiragana && candidate == katakana else { return true }
            // カタカナ・ひらがな以外の実質的な変換候補がない（未知語）場合のみ
            // insertedSet からも外して末尾のカタカナセクションに表示させる
            let hasRealCandidates = sources.azooKeyCandidates.contains { $0 != katakana && $0 != hiragana }
            if !hasRealCandidates { insertedSet.remove(candidate) }
            return false
        }
        if !azooKeyItems.isEmpty {
            sections.append(CandidateSection(kind: .azooKeyDict, items: azooKeyItems))
        }

        if !hiragana.allSatisfy({ $0.isASCII }), insertedSet.insert(katakana).inserted {
            sections.append(CandidateSection(kind: .katakana, items: [katakana]))
        }

        return sections
    }

    private func assembleCandidateList(from sources: CandidateListSources, autoShow: Bool) -> CandidateAction {
        let h = sources.h
        let numberCandidates = InputHandler.generateNumberCandidates(for: h)
        let dateTimeCandidates = InputHandler.generateDateTimeCandidates(for: h)

        // POC（2026-05-28, observation.md）: 1 モーラサジェストの信頼度ゲート。
        // 拗音（ゃゅょ等の小書き仮名）は独立モーラではないので、`じょ`/`きょ`/`しゃ` も
        // 1 モーラ扱いでゲート対象。`あい`（2 モーラ）等は対象外で通常パスへ。
        // 数字/日時候補があるときは通常パスに任せる。
        let smallKana: Set<Character> = ["ゃ", "ゅ", "ょ", "ゎ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ"]
        let primaryKanaCount = h.filter { !smallKana.contains($0) }.count
        let isSingleMora = !h.isEmpty && primaryKanaCount == 1 && !h.allSatisfy({ $0.isASCII })
        if autoShow, isSingleMora, numberCandidates.isEmpty, dateTimeCandidates.isEmpty {
            let recents = recentCommitsMatching(prefix: h)
            // 読みが助詞・ひらがな固定語（てにをはが 等）のとき: ひらがなを row 0 に固定し、
            // その下に前方一致の過去語を並べる（observation.md 1モーラサジェスト・2026-05-29 調整）。
            // ひらがな優先なので Space/Enter ではまず h が確定し、過去語は矢印で選べる。両立させる狙い。
            if isHiraganaPreferred(h) {
                let rest = recents.filter { $0 != h }
                // 並べる過去語がなければ単独ひらがなの窓は無意味なので出さない（組成のまま継続）。
                guard !rest.isEmpty else { return .dismiss }
                let candidates = [h] + rest
                return .show(
                    candidates: candidates,
                    historyEnd: candidates.count,
                    initialRow: 0,
                    predictionEnd: candidates.count,
                    fixedEnd: 1
                )
            }
            guard !recents.isEmpty else { return .dismiss }
            // 第一候補が機能語なら（「は」→「は」のような自己一致など）抑制
            if HiraganaPreferredBuiltins.words[recents[0]] != nil {
                return .dismiss
            }
            return .show(
                candidates: recents,
                historyEnd: recents.count,
                initialRow: 0,
                predictionEnd: recents.count,
                fixedEnd: 0
            )
        }

        if autoShow && sources.totalHistoryCount == 0 && sources.azooKeyCandidates.isEmpty && sources.predictCount == 0
            && sources.userDictRaw.isEmpty && dateTimeCandidates.isEmpty && numberCandidates.isEmpty {
            return .dismiss
        }

        let hiragana = state.composedHiragana
        let predictCount = sources.predictCount
        let highHistoryCount = sources.highHistoryCount
        let basePool = sources.uniquePredictions + sources.highHistory + sources.azooKeyUniq
        let hiraganaInHistory = basePool.prefix(predictCount + highHistoryCount).contains(hiragana)
        let fixedSlot = resolveFixedSlot(reading: h, hiraganaInHistory: hiraganaInHistory)

        let addsDefaultFixedHiragana = shouldAddDefaultFixedHiragana(
            autoShow: autoShow,
            fixedSlot: fixedSlot,
            hiraganaInHistory: hiraganaInHistory,
            sources: sources,
            numberCandidates: numberCandidates,
            dateTimeCandidates: dateTimeCandidates
        )
        let sections = buildSections(
            from: sources,
            fixedSlot: fixedSlot,
            hiraganaInHistory: hiraganaInHistory,
            addsDefaultFixedHiragana: addsDefaultFixedHiragana,
            numberCandidates: numberCandidates,
            dateTimeCandidates: dateTimeCandidates
        )
        let zenzaiLeads = addsDefaultFixedHiragana && sources.zenzaiPromoted != nil
        let layout = CandidateLayout(
            sections: sections,
            sectionOrder: zenzaiLeads ? CandidateLayout.zenzaiFirstSectionOrder : CandidateLayout.defaultSectionOrder,
            initialRowPolicy: resolveInitialRowPolicy(
                sources: sources,
                fixedSlot: fixedSlot,
                hiraganaInHistory: hiraganaInHistory,
                addsDefaultFixedHiragana: addsDefaultFixedHiragana
            )
        )
        guard !layout.candidates.isEmpty else { return .dismiss }

        // POC（2026-05-28, observation.md 参照）: 打鍵中の autoShow で第一候補が機能語
        // （`HiraganaPreferredBuiltins.words` に登録された助詞・助動詞・接続詞等）の場合、
        // タイピングリズムを邪魔しないようサジェスト UI を出さない。Space 押下時 (autoShow=false)
        // は通常通り候補を出す。
        if autoShow,
           layout.initialRow < layout.candidates.count,
           HiraganaPreferredBuiltins.words[layout.candidates[layout.initialRow]] != nil {
            return .dismiss
        }

        return .show(
            candidates: layout.candidates,
            historyEnd: layout.historyEnd,
            initialRow: layout.initialRow,
            predictionEnd: layout.predictionEnd,
            fixedEnd: layout.fixedEnd
        )
    }
}
