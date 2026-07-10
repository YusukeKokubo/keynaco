import Foundation

/// `CandidateScoreBuilder` の結果を候補列・source 配列に展開する。
enum CandidateScoredLayout {

    struct Input: Sendable {
        let scored: [ScoredCandidate]
    }

    struct Result: Sendable {
        let candidates: [String]
        let sources: [ScoredCandidate.Source]
        /// 行ごとの助詞トリム可否（PLAN260710a）。`candidates` と同長。
        let trimFlags: [Bool]
        /// 先頭から連続する hiragana preferred 行数（Zenzai 診断用）。
        let fixedEnd: Int
    }

    /// スコア降順リストをそのまま flatten。
    static func assemble(_ input: Input) -> Result {
        var candidates: [String] = []
        var sources: [ScoredCandidate.Source] = []
        var trimFlags: [Bool] = []
        var seen = Set<String>()

        for item in input.scored where seen.insert(item.text).inserted {
            candidates.append(item.text)
            sources.append(item.source)
            trimFlags.append(item.shouldTrimTrailingJoshi)
        }

        return Result(
            candidates: candidates,
            sources: sources,
            trimFlags: trimFlags,
            fixedEnd: CandidateRowMetadata.fixedEnd(sources: sources)
        )
    }
}
