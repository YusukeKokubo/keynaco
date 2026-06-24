import Foundation

/// 履歴 1 件の正規化表現（PLAN260624d）。
///
/// 同 output に対し `fetchHistoryExactScored`（`input = reading` の単行スコア）と
/// `fetchHistoryScoredMerged`（`LIKE 'reading%'` の SUM）の両方が値を持ちうるため、
/// 1 エントリに `exactScore` / `prefixScore` を併存させる。
///
/// `CandidateScoreBuilder` はエントリごとに最大 2 つの `ScoredCandidate` を生成し
/// （exact / prefix それぞれ source ラベルを持つ）、`upsert` の dedup ロジックで
/// 同 text の最高スコアが残る。
public struct HistoryEntry: Sendable, Equatable {
    public let output: String
    public let exactScore: Double?
    public let prefixScore: Double?

    public init(output: String, exactScore: Double? = nil, prefixScore: Double? = nil) {
        self.output = output
        self.exactScore = exactScore
        self.prefixScore = prefixScore
    }
}
