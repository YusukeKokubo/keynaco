import Foundation

/// `CandidateScoreBuilder` の結果を候補列・境界インデックスに展開する。
enum CandidateScoredLayout {

    struct Input: Sendable {
        let hiragana: String
        let fixedSlot: CandidateFixedSlot
        let scored: [ScoredCandidate]
        let numberCandidates: [String]
        let dateTimeCandidates: [String]
        /// 固定ひらがな枠の重複判定用。
        let historyOutputSet: Set<String>
    }

    struct Result: Sendable {
        let candidates: [String]
        let fixedEnd: Int
        let historyEnd: Int
    }

    /// 履歴ブロック（score 降順）→ 辞書ブロック（score 降順）の 2 段。`historyEnd` は Shift+Delete 用。
    static func assemble(_ input: Input) -> Result {
        let historyItems = input.scored.filter { CandidateScoreBuilder.isHistorySource($0.source) }
        let dictItems = input.scored.filter { !CandidateScoreBuilder.isHistorySource($0.source) }

        var candidates: [String] = []
        var seen = Set<String>()
        var fixedEnd = 0

        if input.fixedSlot == .hiragana {
            candidates.append(input.hiragana)
            seen.insert(input.hiragana)
            fixedEnd = 1
        }

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
