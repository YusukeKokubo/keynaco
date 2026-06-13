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
    /// 読み完全一致の履歴（スコア順）。非空なら初期選択する。
    let exactMatchHighHistory: [String]
    /// 読み完全一致のユーザー辞書エントリ。履歴より弱く、AzooKey 辞書より強い。
    let userDictExact: [String]
    /// AzooKey 辞書が返した候補（読み完全一致）。履歴・ユーザー辞書が無いとき先頭を初期選択。
    let azooKeyCandidates: [String]
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
            if let first = input.userDictExact.first {
                return .firstMatching(first)
            }
            if let first = input.azooKeyCandidates.first {
                if first != input.reading,
                   input.reading.hasPrefix(first),
                   first.count < input.reading.count,
                   input.azooKeyCandidates.contains(input.reading) {
                    return .firstMatching(input.reading)
                }
                return .firstMatching(first)
            }
            if input.addsDefaultFixedHiragana {
                return .firstMatching(input.reading)
            }
            return .afterFixed
        }
    }
}
