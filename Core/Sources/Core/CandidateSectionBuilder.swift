import Foundation

struct CandidateSectionBuildInput: Sendable {
    let reading: String
    let hiragana: String
    let katakana: String
    let azooKeyCandidates: [String]
    let userDictRaw: [String]
    let highHistory: [String]
    /// `fetchHistoryScoredMerged` の全 output（固定ひらがな枠の重複判定用）。
    let historyOutputSet: Set<String>
    /// 組成読み（marked ひらがな）と `input` が完全一致する履歴 output。
    let exactMatchHistoryOutputs: Set<String>
    let zenzaiPromoted: String?
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
        let azooKeyUniq = input.azooKeyCandidates.filter { candidate in
            guard candidate != input.zenzaiPromoted else { return false }
            if input.highHistory.contains(candidate) { return false }
            // 前方一致のみの履歴は表示されないので辞書からも除外。読み完全一致は top3 外でも選べるよう残す。
            if input.historyOutputSet.contains(candidate),
               !input.exactMatchHistoryOutputs.contains(candidate) {
                return false
            }
            return true
        }

        var sections: [CandidateSection] = []
        var seen = Set<String>(minimumCapacity: input.highHistory.count + azooKeyUniq.count)
        for item in input.highHistory { seen.insert(item) }
        for item in azooKeyUniq { seen.insert(item) }

        if input.fixedSlot == .hiragana || input.addsDefaultFixedHiragana {
            // allCandidatesSeen（全候補のスナップショット）にある場合は、seen から一度外して
            // 固定枠が先取りできるようにし、追加後に再登録して後続の重複排除を機能させる。
            if allCandidatesSeen.contains(input.hiragana) { seen.remove(input.hiragana) }
            sections.append(CandidateSection(kind: .fixedHiragana, items: [input.hiragana]))
            seen.insert(input.hiragana)
        }

        addSection(.userDict, from: input.userDictRaw, seen: &seen, into: &sections)

        if let top1 = input.zenzaiPromoted, seen.insert(top1).inserted {
            sections.append(CandidateSection(kind: .zenzaiTop1, items: [top1]))
        }

        let azooKeyItems = azooKeyUniq.filter { candidate in
            guard input.addsDefaultFixedHiragana && candidate == input.katakana else { return true }
            let hasRealCandidates = input.azooKeyCandidates.contains {
                $0 != input.katakana && $0 != input.hiragana
            }
            if !hasRealCandidates { seen.remove(candidate) }
            return false
        }
        if !azooKeyItems.isEmpty {
            sections.append(CandidateSection(kind: .azooKeyDict, items: azooKeyItems))
        }

        if !input.highHistory.isEmpty {
            sections.append(CandidateSection(kind: .highHistory, items: input.highHistory))
        }

        addSection(.number, from: input.numberCandidates, seen: &seen, into: &sections)
        addSection(.dateTime, from: input.dateTimeCandidates, seen: &seen, into: &sections)

        if !input.hiragana.allSatisfy({ $0.isASCII }),
           seen.insert(input.katakana).inserted {
            sections.append(CandidateSection(kind: .katakana, items: [input.katakana]))
        }

        let sectionOrder = input.addsDefaultFixedHiragana && input.zenzaiPromoted != nil
            ? CandidateLayout.zenzaiFirstSectionOrder
            : CandidateLayout.defaultSectionOrder

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
