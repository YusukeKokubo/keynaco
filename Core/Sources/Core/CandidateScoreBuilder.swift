import Foundation

/// 履歴・ユーザー辞書・AzooKey を単一スコア空間に載せる（PLAN260624 Phase 1）。
enum CandidateScoreBuilder {

    /// DB `recencyExpr` と同じ載せ/載せない境界。
    static let historyScoreCutoff = 0.5
    /// ユーザー辞書 exact（POC 値。Phase 1 暫定）。
    static let userDictExactScore = 50.0
    /// ユーザー辞書 prefix（POC 値。Phase 1 暫定）。
    static let userDictPrefixScore = 30.0

    struct BuildInput: Sendable {
        let exactMatchHighHistory: [String]
        let highHistory: [String]
        let exactMatchScores: [String: Double]
        let prefixHistoryScores: [String: Double]
        let userDictExact: [String]
        let userDictPrefix: [String]
        let azooKeyCandidates: [String]
        /// Zenzai 込み API 順。空なら rank ボーナスなし。
        let azooKeyApiOrder: [String]
    }

    static func azooKeyScore(rank: Int) -> Double {
        10.0 / (1.0 + Double(rank))
    }

    /// 全ソースを flatten → dedup（最高スコア）→ スコア降順。
    static func build(_ input: BuildInput) -> [ScoredCandidate] {
        var byText: [String: ScoredCandidate] = [:]
        var insertionOrder: [String] = []

        func upsert(_ candidate: ScoredCandidate) {
            if let existing = byText[candidate.text] {
                if candidate.score > existing.score
                    || (candidate.score == existing.score
                        && sourceSortKey(candidate.source) < sourceSortKey(existing.source)) {
                    byText[candidate.text] = candidate
                }
            } else {
                byText[candidate.text] = candidate
                insertionOrder.append(candidate.text)
            }
        }

        for output in input.exactMatchHighHistory {
            guard let score = input.exactMatchScores[output],
                  score >= historyScoreCutoff else { continue }
            upsert(ScoredCandidate(text: output, score: score, source: .historyExact))
        }

        for output in input.highHistory {
            guard let score = input.prefixHistoryScores[output],
                  score >= historyScoreCutoff else { continue }
            upsert(ScoredCandidate(text: output, score: score, source: .historyPrefix))
        }

        for output in input.userDictExact {
            upsert(ScoredCandidate(
                text: output,
                score: Self.userDictExactScore,
                source: .userDict(isExact: true)
            ))
        }

        for output in input.userDictPrefix {
            upsert(ScoredCandidate(
                text: output,
                score: Self.userDictPrefixScore,
                source: .userDict(isExact: false)
            ))
        }

        let historyTexts = Set(byText.keys)
        for (rank, text) in input.azooKeyCandidates.enumerated() {
            guard !historyTexts.contains(text) else { continue }
            upsert(ScoredCandidate(
                text: text,
                score: azooKeyScore(rank: rank),
                source: .azooKey(rank: rank)
            ))
        }

        let sorted = insertionOrder.compactMap { byText[$0] }.sorted { lhs, rhs in
            compare(lhs, rhs, azooKeyApiOrder: input.azooKeyApiOrder)
        }
        return sorted
    }

    static func isHistorySource(_ source: ScoredCandidate.Source) -> Bool {
        switch source {
        case .historyExact, .historyPrefix: return true
        default: return false
        }
    }

    private static func sourceSortKey(_ source: ScoredCandidate.Source) -> Int {
        switch source {
        case .historyExact: return 0
        case .historyPrefix: return 1
        case .userDict: return 2
        case .azooKey: return 3
        case .hiraganaPreferred: return 4
        case .hiraganaBuiltin: return 5
        case .number: return 6
        case .dateTime: return 7
        }
    }

    private static func compare(
        _ lhs: ScoredCandidate,
        _ rhs: ScoredCandidate,
        azooKeyApiOrder: [String]
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let lp = sourceSortKey(lhs.source)
        let rp = sourceSortKey(rhs.source)
        if lp != rp { return lp < rp }
        if case .azooKey(let lr) = lhs.source, case .azooKey(let rr) = rhs.source, lr != rr {
            return lr < rr
        }
        if case .historyExact = lhs.source, case .historyExact = rhs.source,
           !azooKeyApiOrder.isEmpty {
            let rankByText = Dictionary(
                azooKeyApiOrder.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
            switch (rankByText[lhs.text], rankByText[rhs.text]) {
            case let (la?, ra?): return la < ra
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
        }
        return false
    }
}
