import Foundation

/// 履歴 1 件の正規化表現（PLAN260624d）。
///
/// 同 output に対し `fetchHistoryExactScored`（`input = reading` の単行スコア）と
/// `fetchHistoryScoredMerged`（`LIKE 'reading%'` の SUM）の両方が値を持ちうるため、
/// 1 エントリに exact / prefix の score を併存させる。
///
/// `ScoreKind` で「exact のみ」「prefix のみ」「両方」の 3 状態を表現し、
/// 「両方 nil」の不正状態を型レベルで排除する。
///
/// `CandidateScoreBuilder` はエントリごとに最大 2 つの `ScoredCandidate` を生成し
/// （exact / prefix それぞれ source ラベルを持つ）、`upsert` の dedup ロジックで
/// 同 text の最高スコアが残る。
public struct HistoryEntry: Sendable, Equatable {
    public enum ScoreKind: Sendable, Equatable {
        case exact(Double)
        case prefix(Double)
        case both(exact: Double, prefix: Double)
    }

    public let output: String
    public let score: ScoreKind

    public init(output: String, score: ScoreKind) {
        self.output = output
        self.score = score
    }

    /// 既存の prefix score を保ったまま exact score を上書き（または追加）する。
    public func addingExact(_ exact: Double) -> HistoryEntry {
        let newScore: ScoreKind
        switch score {
        case .exact, .both:
            // 同 output で exact が 2 回呼ばれることはないが、最後勝ちで素直に置換。
            newScore = score.prefixValue.map { .both(exact: exact, prefix: $0) } ?? .exact(exact)
        case .prefix(let p):
            newScore = .both(exact: exact, prefix: p)
        }
        return HistoryEntry(output: output, score: newScore)
    }

    /// 既存の exact score を保ったまま prefix score を上書き（または追加）する。
    public func addingPrefix(_ prefix: Double) -> HistoryEntry {
        let newScore: ScoreKind
        switch score {
        case .prefix, .both:
            newScore = score.exactValue.map { .both(exact: $0, prefix: prefix) } ?? .prefix(prefix)
        case .exact(let e):
            newScore = .both(exact: e, prefix: prefix)
        }
        return HistoryEntry(output: output, score: newScore)
    }

    /// 互換 API: `.exact` / `.both` のときだけ exact score を返す。
    public var exactScore: Double? { score.exactValue }
    /// 互換 API: `.prefix` / `.both` のときだけ prefix score を返す。
    public var prefixScore: Double? { score.prefixValue }
}

extension HistoryEntry.ScoreKind {
    public var exactValue: Double? {
        switch self {
        case .exact(let s), .both(let s, _): return s
        case .prefix: return nil
        }
    }
    public var prefixValue: Double? {
        switch self {
        case .prefix(let s), .both(_, let s): return s
        case .exact: return nil
        }
    }
}
