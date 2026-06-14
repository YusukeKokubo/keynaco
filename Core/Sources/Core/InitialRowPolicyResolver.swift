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
    /// 打鍵中のみ: 前方一致履歴/ユーザー辞書のうち品詞・モーラ数条件を満たす初期フォーカス候補。
    let prefixFocusCandidate: String?
    /// AzooKey 辞書が返した候補（読み完全一致）。履歴・ユーザー辞書が無いとき先頭を初期選択。
    let azooKeyCandidates: [String]
    /// セクション統合後の候補列（初期行判定用）。
    let candidateList: [String]
}

enum InitialRowPolicyResolver {
    /// 前方一致履歴 → ユーザー辞書 prefix の順で、品詞ごとの最低モーラ数を満たす先頭を返す。
    ///
    /// - 名詞・固有名詞: 2 モーラ以上
    /// - 動詞: 3 モーラ以上
    /// - その他（形容詞・未分類等）: 5 モーラ以上
    /// - 助詞・助動詞: 対象外
    static func prefixFocusCandidate(
        reading: String,
        prefixHistory: [String],
        userDictPrefix: [String],
        lcidForOutput: (String) -> Int?
    ) -> String? {
        let moraCount = KanaUtils.moraCount(in: reading)
        guard moraCount >= 2 else { return nil }
        for text in prefixHistory {
            if acceptsPrefixFocus(readingMoraCount: moraCount, lcid: lcidForOutput(text)) {
                return text
            }
        }
        for text in userDictPrefix {
            if acceptsPrefixFocus(readingMoraCount: moraCount, lcid: lcidForOutput(text)) {
                return text
            }
        }
        return nil
    }

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
            if let focus = input.prefixFocusCandidate {
                return .firstMatching(focus)
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
            if input.addsDefaultFixedHiragana {
                return .firstMatching(input.reading)
            }
            return .afterFixed
        }
    }

    private static func minimumMoraeForPrefixFocus(lcid: Int?) -> Int? {
        switch LcidRank.from(lcid: lcid) {
        case .noun, .properNoun: return 2
        case .verb: return 3
        case .adjective, .unknown: return 5
        case .particle, .auxiliary: return nil
        }
    }

    private static func acceptsPrefixFocus(readingMoraCount: Int, lcid: Int?) -> Bool {
        guard let minimum = minimumMoraeForPrefixFocus(lcid: lcid) else { return false }
        return readingMoraCount >= minimum
    }
}
