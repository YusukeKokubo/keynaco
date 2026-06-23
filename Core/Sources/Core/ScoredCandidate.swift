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

    public init(text: String, score: Double, source: Source) {
        self.text = text
        self.score = score
        self.source = source
    }
}
