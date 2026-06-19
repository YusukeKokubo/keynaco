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
    private enum MoraThreshold {
        static let noun = 2
        static let verb = 3
        static let other = 5
    }

    /// 前方一致フォーカス用の品詞ランク。`lcid` → `pos`（NULL 行のみ）→ `.unknown`。
    static func rankForPrefixFocus(output: String, db: DatabaseManager) -> LcidRank {
        if let lcid = db.lcidForOutput(output) {
            return LcidRank.from(lcid: lcid)
        }
        if let pos = db.posForOutput(output) {
            return LcidRank.from(pos: pos)
        }
        return .unknown
    }

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
        rankForOutput: (String) -> LcidRank
    ) -> String? {
        let moraCount = KanaUtils.moraCount(in: reading)
        guard moraCount >= MoraThreshold.noun else { return nil }
        for text in prefixHistory {
            if acceptsPrefixFocus(readingMoraCount: moraCount, rank: rankForOutput(text)) {
                return text
            }
        }
        for text in userDictPrefix {
            if acceptsPrefixFocus(readingMoraCount: moraCount, rank: rankForOutput(text)) {
                return text
            }
        }
        return nil
    }

    /// 打鍵中: 閾値未満の前方一致履歴行を初期行から外し、辞書/カタカナ側へ進める。
    /// 読み完全一致履歴は閾値なしで維持する。フォーカス可能な行が無ければ nil（候補 UI 非表示）。
    static func whileTypingInitialRow(
        candidates: [String],
        fixedEnd: Int,
        historyEnd: Int,
        computedRow: Int,
        reading: String,
        exactMatchHistory: Set<String>,
        rankForOutput: (String) -> LcidRank
    ) -> Int? {
        guard !candidates.isEmpty, fixedEnd <= historyEnd else { return computedRow }
        let moraCount = KanaUtils.moraCount(in: reading)

        func historyRowEligible(at index: Int) -> Bool {
            guard index >= fixedEnd, index < historyEnd else { return false }
            let text = candidates[index]
            if exactMatchHistory.contains(text) { return true }
            return acceptsPrefixFocus(readingMoraCount: moraCount, rank: rankForOutput(text))
        }

        if computedRow < candidates.count, computedRow < fixedEnd || computedRow >= historyEnd {
            return computedRow
        }
        if computedRow < candidates.count, historyRowEligible(at: computedRow) {
            return computedRow
        }

        for index in fixedEnd..<candidates.count {
            if index >= historyEnd { return index }
            if historyRowEligible(at: index) { return index }
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
            return .afterFixed
        }
    }

    private static func minimumMorae(for rank: LcidRank) -> Int? {
        switch rank {
        case .noun, .properNoun: return MoraThreshold.noun
        case .verb: return MoraThreshold.verb
        case .adjective: return MoraThreshold.verb
        case .unknown: return MoraThreshold.other
        case .particle, .auxiliary: return nil
        }
    }

    private static func acceptsPrefixFocus(readingMoraCount: Int, rank: LcidRank) -> Bool {
        guard let minimum = minimumMorae(for: rank) else { return false }
        return readingMoraCount >= minimum
    }
}
