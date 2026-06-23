import Foundation

/// `CandidateScoreBuilder` の結果を候補列・境界インデックスに展開する。
enum CandidateScoredLayout {

    struct Input: Sendable {
        let scored: [ScoredCandidate]
    }

    struct Result: Sendable {
        let candidates: [String]
        let sources: [ScoredCandidate.Source]
        /// UI 区切り用（先頭から連続する fixed / history ブロック）。Shift+Delete は `sources` を正本とする。
        let fixedEnd: Int
        let historyEnd: Int
    }

    /// スコア降順リストをそのまま flatten。`fixedEnd` / `historyEnd` は後方互換の連続ブロック境界。
    static func assemble(_ input: Input) -> Result {
        var candidates: [String] = []
        var sources: [ScoredCandidate.Source] = []
        var seen = Set<String>()

        for item in input.scored where seen.insert(item.text).inserted {
            candidates.append(item.text)
            sources.append(item.source)
        }

        let (fixedEnd, historyEnd) = CandidateRowMetadata.legacyBoundaries(sources: sources)
        return Result(
            candidates: candidates,
            sources: sources,
            fixedEnd: fixedEnd,
            historyEnd: historyEnd
        )
    }
}
