import Foundation

/// 先頭固定枠の種別（hiraganaPreferred 時のひらがな固定等）。
enum CandidateFixedSlot: Equatable, Sendable {
    case none
    case hiragana
}

struct InitialRowPolicyInput: Equatable, Sendable {
    let reading: String
    let fixedSlot: CandidateFixedSlot
    let hiraganaInHistory: Bool
    let addsDefaultFixedHiragana: Bool
    let zenzaiPromoted: String?
}

enum InitialRowPolicyResolver {
    static func resolve(_ input: InitialRowPolicyInput) -> InitialRowPolicy {
        switch input.fixedSlot {
        case .hiragana:
            return .firstMatching(input.reading)
        case .none:
            if input.addsDefaultFixedHiragana {
                if input.zenzaiPromoted != nil { return .atZero }
                return .firstMatching(input.reading)
            }
            if input.hiraganaInHistory, input.zenzaiPromoted != nil {
                return .firstMatching(input.reading)
            }
            if input.zenzaiPromoted != nil { return .atZero }
            return .afterFixed
        }
    }
}
