import Foundation

/// 履歴・ユーザー辞書・AzooKey を単一スコア空間に載せる（PLAN260624 Phase 1）。
enum CandidateScoreBuilder {

    /// DB `recencyExpr` と同じ載せ/載せない境界。
    static let historyScoreCutoff = 0.5
    /// ユーザー辞書 exact（POC 値。Phase 1 暫定）。
    static let userDictExactScore = 50.0
    /// ユーザー辞書 prefix（POC 値。Phase 1 暫定）。
    static let userDictPrefixScore = 30.0
    /// ユーザー設定 hiraganaPreferred（POC 値。Phase 2 暫定）。
    static let hiraganaUserBonus = 100.0
    /// 組み込み助詞等 HiraganaPreferredBuiltins（POC 値。Phase 2 暫定）。
    static let hiraganaBuiltinBonus = 80.0
    /// 数値・日時特殊変換（POC 値。PLAN260624）。
    static let specialCandidateScore = 5.0

    enum HiraganaBonusKind: Sendable, Equatable {
        case userSetting
        case builtin
    }

    struct BuildInput: Sendable {
        let reading: String
        let hiraganaBonus: HiraganaBonusKind?
        /// 履歴 1 件は exact / prefix どちらか or 両方の score を持つ（PLAN260624d）。
        let historyEntries: [HistoryEntry]
        let userDictExact: [String]
        let userDictPrefix: [String]
        let azooKeyCandidates: [String]
        /// Zenzai 込み API 順。空なら rank ボーナスなし。
        let azooKeyApiOrder: [String]
        let numberCandidates: [String]
        let dateTimeCandidates: [String]
        /// `.explicit`（Space 押下）では入力より長い読みの候補（`historyPrefix` /
        /// `userDict(isExact: false)`）を exact-reading 候補の下位に置く。
        /// 「Space = 今の入力での変換を期待」という user の意思表示に合わせる。
        /// `.whileTyping`（autoShow）は単語補完 UX のため現状維持。
        let trigger: CandidateListTrigger
    }

    static func azooKeyScore(rank: Int) -> Double {
        10.0 / (1.0 + Double(rank))
    }

    /// 載せた履歴は AzooKey rank 0 より前に並べる（flatten 後も辞書より優先）。
    private static func historyDisplayScore(_ dbScore: Double) -> Double {
        max(dbScore, azooKeyScore(rank: 0) + 0.001)
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

        for entry in input.historyEntries {
            if let score = entry.exactScore, score >= historyScoreCutoff {
                upsert(ScoredCandidate(
                    text: entry.output,
                    score: historyDisplayScore(score),
                    source: .historyExact
                ))
            }
            if let score = entry.prefixScore, score >= historyScoreCutoff {
                upsert(ScoredCandidate(
                    text: entry.output,
                    score: historyDisplayScore(score),
                    source: .historyPrefix
                ))
            }
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

        if let bonusKind = input.hiraganaBonus {
            let bonusScore = bonusKind == .userSetting
                ? Self.hiraganaUserBonus
                : Self.hiraganaBuiltinBonus
            let bonusSource: ScoredCandidate.Source = bonusKind == .userSetting
                ? .hiraganaPreferred
                : .hiraganaBuiltin
            let text = input.reading
            if let existing = byText[text], isHistorySource(existing.source) {
                if bonusScore >= existing.score {
                    byText[text] = ScoredCandidate(text: text, score: bonusScore, source: bonusSource)
                }
            } else {
                upsert(ScoredCandidate(text: text, score: bonusScore, source: bonusSource))
            }
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

        for text in input.numberCandidates {
            upsert(ScoredCandidate(text: text, score: specialCandidateScore, source: .number))
        }
        for text in input.dateTimeCandidates {
            upsert(ScoredCandidate(text: text, score: specialCandidateScore, source: .dateTime))
        }

        let azooKeyRankByText: [String: Int]? = input.azooKeyApiOrder.isEmpty
            ? nil
            : Dictionary(
                input.azooKeyApiOrder.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
        let demotePrefixExtended = input.trigger == .explicit
        let sorted = insertionOrder.compactMap { byText[$0] }.sorted { lhs, rhs in
            compare(
                lhs, rhs,
                azooKeyRankByText: azooKeyRankByText,
                demotePrefixExtended: demotePrefixExtended
            )
        }
        return sorted
    }

    static func isHistorySource(_ source: ScoredCandidate.Source) -> Bool {
        switch source {
        case .historyExact, .historyPrefix: return true
        default: return false
        }
    }

    static func isHiraganaPreferredSource(_ source: ScoredCandidate.Source) -> Bool {
        switch source {
        case .hiraganaPreferred, .hiraganaBuiltin: return true
        default: return false
        }
    }

    /// 入力より長い読みの候補（`historyPrefix` / `userDict(isExact: false)`）。
    /// `.explicit` トリガーで exact-reading 候補より絶対下位に置くために使う。
    static func isPrefixExtendedSource(_ source: ScoredCandidate.Source) -> Bool {
        switch source {
        case .historyPrefix: return true
        case .userDict(let isExact): return !isExact
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
        azooKeyRankByText: [String: Int]?,
        demotePrefixExtended: Bool
    ) -> Bool {
        if demotePrefixExtended {
            let lExt = isPrefixExtendedSource(lhs.source)
            let rExt = isPrefixExtendedSource(rhs.source)
            if lExt != rExt { return !lExt }
        }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let lp = sourceSortKey(lhs.source)
        let rp = sourceSortKey(rhs.source)
        if lp != rp { return lp < rp }
        if case .azooKey(let lr) = lhs.source, case .azooKey(let rr) = rhs.source, lr != rr {
            return lr < rr
        }
        if case .historyExact = lhs.source, case .historyExact = rhs.source,
           let rankByText = azooKeyRankByText {
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
