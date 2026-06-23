import Foundation

/// 候補リスト統一スコアランキングの中間表現（PLAN260624）。
struct ScoredCandidate: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case historyExact
        case historyPrefix
        case userDict(isExact: Bool)
        case azooKey(rank: Int)
        case hiraganaPreferred
        case hiraganaBuiltin
        case number
        case dateTime
    }

    let text: String
    let score: Double
    let source: Source
}
