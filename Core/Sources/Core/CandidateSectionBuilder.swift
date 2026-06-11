import Foundation

struct CandidateSectionBuildInput: Sendable {
    let reading: String
    let hiragana: String
    let katakana: String
    let azooKeyCandidates: [String]
    let userDictRaw: [String]
    let highHistory: [String]
    let historyOutputSet: Set<String>
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
        let azooKeyUniq = input.azooKeyCandidates.filter {
            !input.historyOutputSet.contains($0) && $0 != input.zenzaiPromoted
        }

        var sections: [CandidateSection] = []
        var seen = Set(input.highHistory + azooKeyUniq)

        switch input.fixedSlot {
        case .hiragana:
            if allCandidatesSeen.contains(input.hiragana) { seen.remove(input.hiragana) }
            sections.append(CandidateSection(kind: .fixedHiragana, items: [input.hiragana]))
            seen.insert(input.hiragana)
        case .none:
            if input.addsDefaultFixedHiragana {
                if allCandidatesSeen.contains(input.hiragana) { seen.remove(input.hiragana) }
                sections.append(CandidateSection(kind: .fixedHiragana, items: [input.hiragana]))
                seen.insert(input.hiragana)
            }
        }

        let uniqueUserDict = input.userDictRaw.filter { seen.insert($0).inserted }
        if !uniqueUserDict.isEmpty {
            sections.append(CandidateSection(kind: .userDict, items: uniqueUserDict))
        }

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

        let uniqueNumberCandidates = input.numberCandidates.filter { seen.insert($0).inserted }
        if !uniqueNumberCandidates.isEmpty {
            sections.append(CandidateSection(kind: .number, items: uniqueNumberCandidates))
        }

        let uniqueDateTimeCandidates = input.dateTimeCandidates.filter { seen.insert($0).inserted }
        if !uniqueDateTimeCandidates.isEmpty {
            sections.append(CandidateSection(kind: .dateTime, items: uniqueDateTimeCandidates))
        }

        if !input.hiragana.allSatisfy({ $0.isASCII }),
           seen.insert(input.katakana).inserted {
            sections.append(CandidateSection(kind: .katakana, items: [input.katakana]))
        }

        let sectionOrder = input.addsDefaultFixedHiragana && input.zenzaiPromoted != nil
            ? CandidateLayout.zenzaiFirstSectionOrder
            : CandidateLayout.defaultSectionOrder

        return CandidateSectionBuildResult(sections: sections, sectionOrder: sectionOrder)
    }
}
