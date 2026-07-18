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
    /// テキスト一意性は `CandidateScoreBuilder.build` が保証する（PLAN260718 で二重 dedup を廃止）。
    static func assemble(_ input: Input) -> Result {
        var candidates: [String] = []
        var sources: [ScoredCandidate.Source] = []
        var trimFlags: [Bool] = []

        for item in input.scored {
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
