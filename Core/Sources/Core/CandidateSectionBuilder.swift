import Foundation

struct CandidateSectionBuildInput: Sendable {
    let reading: String
    let hiragana: String
    let azooKeyCandidates: [String]
    /// Zenzai 込みの AzooKey 内部順序。`exactMatchHighHistory` の並べ替えに使う。
    let azooKeyApiOrder: [String]
    let userDictRaw: [String]
    let exactMatchHighHistory: [String]
    let highHistory: [String]
    /// `fetchHistoryScoredMerged` の全 output（固定ひらがな枠の重複判定用）。
    let historyOutputSet: Set<String>
    /// 組成読み（marked ひらがな）と `input` が完全一致する履歴 output。
    let exactMatchHistoryOutputs: Set<String>
    let fixedSlot: CandidateFixedSlot
    let addsDefaultFixedHiragana: Bool
    let numberCandidates: [String]
    let dateTimeCandidates: [String]
}

struct CandidateSectionBuildResult: Sendable {
    let sections: [CandidateSection]
    let sectionOrder: [CandidateSection.Kind]
}

enum CandidateSectionBuilder {
    static func build(_ input: CandidateSectionBuildInput) -> CandidateSectionBuildResult {
        let allCandidatesSeen = input.historyOutputSet.union(Set(input.azooKeyCandidates))
        let zenzaiRankByText: [String: Int] = input.azooKeyApiOrder.isEmpty ? [:] :
            Dictionary(input.azooKeyApiOrder.enumerated().map { ($0.element, $0.offset) },
                       uniquingKeysWith: { first, _ in first })
        let sortedExactHistory = input.exactMatchHighHistory.sorted { a, b in
            switch (zenzaiRankByText[a], zenzaiRankByText[b]) {
            case let (ra?, rb?): return ra < rb
            case (.some, nil):   return true
            case (nil, .some):   return false
            case (nil, nil):     return false
            }
        }
        let allHighHistory = sortedExactHistory + input.highHistory
        let azooKeyUniq = input.azooKeyCandidates.filter { candidate in
            // 履歴セクションに載る語は辞書と二重表示しない（top3 漏れの前方一致は辞書に残す）。
            !allHighHistory.contains(candidate)
        }

        var sections: [CandidateSection] = []
        var seen = Set<String>(minimumCapacity: allHighHistory.count + azooKeyUniq.count)
        for item in allHighHistory { seen.insert(item) }
        for item in azooKeyUniq { seen.insert(item) }

        if input.fixedSlot == .hiragana || input.addsDefaultFixedHiragana {
            // allCandidatesSeen（全候補のスナップショット）にある場合は、seen から一度外して
            // 固定枠が先取りできるようにし、追加後に再登録して後続の重複排除を機能させる。
            if allCandidatesSeen.contains(input.hiragana) { seen.remove(input.hiragana) }
            sections.append(CandidateSection(kind: .fixedHiragana, items: [input.hiragana]))
            seen.insert(input.hiragana)
        }

        addSection(.userDict, from: input.userDictRaw, seen: &seen, into: &sections)

        if !azooKeyUniq.isEmpty {
            sections.append(CandidateSection(kind: .azooKeyDict, items: azooKeyUniq))
        }

        if !sortedExactHistory.isEmpty {
            sections.append(CandidateSection(kind: .exactMatchHistory, items: sortedExactHistory))
        }

        if !input.highHistory.isEmpty {
            sections.append(CandidateSection(kind: .highHistory, items: input.highHistory))
        }

        addSection(.number, from: input.numberCandidates, seen: &seen, into: &sections)
        addSection(.dateTime, from: input.dateTimeCandidates, seen: &seen, into: &sections)

        let sectionOrder: [CandidateSection.Kind] = sortedExactHistory.isEmpty
            ? CandidateLayout.defaultSectionOrder
            : CandidateLayout.exactMatchFirstSectionOrder

        return CandidateSectionBuildResult(sections: sections, sectionOrder: sectionOrder)
    }

    private static func addSection(
        _ kind: CandidateSection.Kind,
        from items: [String],
        seen: inout Set<String>,
        into sections: inout [CandidateSection]
    ) {
        let unique = items.filter { seen.insert($0).inserted }
        if !unique.isEmpty {
            sections.append(CandidateSection(kind: kind, items: unique))
        }
    }
}
