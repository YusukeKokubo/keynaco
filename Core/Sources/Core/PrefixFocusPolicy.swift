import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// 打鍵中（`.whileTyping`）の前方一致履歴・ユーザー辞書 prefix を初期行に載せるかどうかの
/// 品詞別モーラ閾値（PLAN260614 / IDEA260614）。`.explicit` では適用しない。
enum PrefixFocusPolicy {

    enum POSRank: Sendable, Equatable {
        case properNoun
        case noun
        case adjective
        case verb
        case unknown
        case particle
        case auxiliary
    }

    private enum MoraThreshold {
        static let noun = 2
        static let verb = 3
        static let other = 5
    }

    /// 品詞ランク解決: DB の `lcid` → `pos` のみ（peek 中の同期辞書 lookup は行わない。PLAN260704b A1）。
    /// `classificationForOutput` で 1 hop + メモ化（PLAN260718）。
    static func rank(output: String, db: DatabaseManager) -> POSRank {
        let classification = db.classificationForOutput(output)
        if let lcid = classification.lcid {
            return rank(fromLcid: lcid)
        }
        if let pos = classification.pos {
            return rank(fromPos: pos)
        }
        return .unknown
    }

    /// 前方一致候補 `output` を打鍵中の初期行に載せてよいか。
    static func acceptsPrefixFocus(
        reading: String,
        output: String,
        db: DatabaseManager
    ) -> Bool {
        let moraCount = KanaUtils.moraCount(in: reading)
        guard moraCount >= MoraThreshold.noun else { return false }
        let posRank = rank(output: output, db: db)
        guard let minimum = minimumMorae(for: posRank) else { return false }
        return moraCount >= minimum
    }

    static func rank(fromLcid lcid: Int) -> POSRank {
        if let pos = AzooKeyLcidMapper.classification(for: lcid)?.pos {
            return rank(fromPos: pos)
        }
        if CIDData.isJoshi(cid: lcid) { return .particle }
        if (369...554).contains(lcid) { return .auxiliary }
        return .unknown
    }

    static func rank(fromPos pos: String) -> POSRank {
        if pos.hasPrefix("proper_noun") { return .properNoun }
        if pos.hasPrefix("noun") { return .noun }
        if pos == "adjective" || pos.hasPrefix("adjective/") { return .adjective }
        if pos == "particle" || pos.hasPrefix("particle/") { return .particle }
        if pos == "verb" || pos.hasPrefix("verb/") { return .verb }
        return .unknown
    }

    static func minimumMorae(for rank: POSRank) -> Int? {
        switch rank {
        case .properNoun, .noun: return MoraThreshold.noun
        case .verb, .adjective: return MoraThreshold.verb
        case .unknown: return MoraThreshold.other
        case .particle, .auxiliary: return nil
        }
    }
}

extension HistoryEntry {

    /// `.whileTyping` 用: prefix score が閾値未満なら exact のみ残すか行ごと落とす。
    func applyingPrefixFocusGate(acceptsPrefix: (String) -> Bool) -> HistoryEntry? {
        switch score {
        case .exact:
            return self
        case .prefix:
            return acceptsPrefix(output) ? self : nil
        case .both(let exact, let prefix):
            if acceptsPrefix(output) {
                return HistoryEntry(output: output, score: .both(exact: exact, prefix: prefix))
            }
            return HistoryEntry(output: output, score: .exact(exact))
        }
    }
}
