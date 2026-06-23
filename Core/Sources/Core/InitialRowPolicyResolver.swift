import Foundation

enum InitialRowPolicy: Equatable, Sendable {
    /// 該当文字列の最初の出現位置。見つからなければ afterFixed にフォールバック。
    case firstMatching(String)
    /// 先頭行（スコア順の fixedEnd 以降。通常は 0）。
    case afterFixed
}

struct InitialRowPolicyInput: Equatable, Sendable {
    let reading: String
    /// 読み完全一致の履歴（スコア順）。非空なら初期選択する。
    let exactMatchHighHistory: [String]
    /// 読み完全一致のユーザー辞書エントリ。履歴より弱く、AzooKey 辞書より強い。
    let userDictExact: [String]
    /// AzooKey 辞書が返した候補（読み完全一致）。履歴・ユーザー辞書が無いとき先頭を初期選択。
    let azooKeyCandidates: [String]
    /// 統合後の候補列（初期行判定用）。
    let candidateList: [String]
}

/// explicit トリガー時の初期行ポリシー。打鍵中はスコア順先頭（`afterFixed`）のみ。
enum InitialRowPolicyResolver {

    static func resolve(_ input: InitialRowPolicyInput) -> InitialRowPolicy {
        if let first = input.exactMatchHighHistory.first {
            return .firstMatching(first)
        }
        if let first = input.userDictExact.first {
            return .firstMatching(first)
        }
        if input.candidateList.first == input.reading {
            return .firstMatching(input.reading)
        }
        if let first = input.azooKeyCandidates.first {
            if first != input.reading,
               input.reading.hasPrefix(first),
               first.count < input.reading.count,
               input.candidateList.contains(input.reading) {
                return .firstMatching(input.reading)
            }
            return .firstMatching(first)
        }
        return .afterFixed
    }
}
