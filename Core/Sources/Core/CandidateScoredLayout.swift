import Foundation

/// `CandidateScoreBuilder` の結果を候補列・境界インデックスに展開する。
enum CandidateScoredLayout {

    struct Input: Sendable {
        let scored: [ScoredCandidate]
        let numberCandidates: [String]
        let dateTimeCandidates: [String]
    }

    struct Result: Sendable {
        let candidates: [String]
        let fixedEnd: Int
        let historyEnd: Int
    }

    /// ひらがな優先 → 履歴 → 数値/日時 → 辞書の 4 段。`fixedEnd` は hiraganaPreferred 行の末尾。
    static func assemble(_ input: Input) -> Result {
        let hiraganaItems = input.scored.filter { CandidateScoreBuilder.isHiraganaPreferredSource($0.source) }
        let historyItems = input.scored.filter { CandidateScoreBuilder.isHistorySource($0.source) }
        let dictItems = input.scored.filter {
            !CandidateScoreBuilder.isHistorySource($0.source)
                && !CandidateScoreBuilder.isHiraganaPreferredSource($0.source)
        }

        var candidates: [String] = []
        var seen = Set<String>()

        for item in hiraganaItems where seen.insert(item.text).inserted {
            candidates.append(item.text)
        }
        let fixedEnd = candidates.count

        for item in historyItems where seen.insert(item.text).inserted {
            candidates.append(item.text)
        }
        let historyEnd = candidates.count

        for text in input.numberCandidates + input.dateTimeCandidates where seen.insert(text).inserted {
            candidates.append(text)
        }

        for item in dictItems where seen.insert(item.text).inserted {
            candidates.append(item.text)
        }

        return Result(candidates: candidates, fixedEnd: fixedEnd, historyEnd: historyEnd)
    }
}
