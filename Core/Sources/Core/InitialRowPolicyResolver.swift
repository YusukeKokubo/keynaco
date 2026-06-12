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
    /// 読み完全一致の履歴（スコア順）。非空なら Zenzai より先に初期選択する。
    let exactMatchHighHistory: [String]
}

enum InitialRowPolicyResolver {
    static func resolve(_ input: InitialRowPolicyInput) -> InitialRowPolicy {
        switch input.fixedSlot {
        case .hiragana:
            return .firstMatching(input.reading)
        case .none:
            if let first = input.exactMatchHighHistory.first {
                return .firstMatching(first)
            }
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
