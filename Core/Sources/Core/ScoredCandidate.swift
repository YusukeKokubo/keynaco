import Foundation

/// 候補リスト統一スコアランキングの中間表現（PLAN260624）。
public struct ScoredCandidate: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case historyExact
        case historyPrefix
        case userDict(isExact: Bool)
        case azooKey(rank: Int)
        case hiraganaPreferred
        case hiraganaBuiltin
        case number
        case dateTime
    }

    public let text: String
    public let score: Double
    public let source: Source
    /// PLAN260710a: azooKey 由来で末尾 joshi セグメントがあるとき true。それ以外は false。
    public let shouldTrimTrailingJoshi: Bool

    public init(
        text: String,
        score: Double,
        source: Source,
        shouldTrimTrailingJoshi: Bool = false
    ) {
        self.text = text
        self.score = score
        self.source = source
        self.shouldTrimTrailingJoshi = shouldTrimTrailingJoshi
    }
}
