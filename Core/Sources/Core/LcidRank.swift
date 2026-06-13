import Foundation

/// 候補・履歴の lcid 並び替え用ランク。値が小さいほど候補ウィンドウで上位。
///
/// レンジ定義の正本は `AzooKeyLcidMapper.rank(for:)`。
enum LcidRank: Int, Comparable, Sendable {
    case properNoun = 0
    case noun = 1
    case adjective = 2
    case verb = 3
    case unknown = 4
    case particle = 5
    case auxiliary = 6
    /// 辞書外の長文フレーズ（`lcid` 欠落かつ `output.count > 10`）。履歴タイブレーカー専用。
    case longPhrase = 7

    static func < (lhs: LcidRank, rhs: LcidRank) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 候補・履歴の正本。AzooKey 接続 ID から rank を返す。
    static func from(lcid: Int?) -> LcidRank {
        AzooKeyLcidMapper.rank(for: lcid)
    }

    /// `lcid` 欠落時のフォールバックのみ。助動詞は表示 `pos` が `verb` のため `auxiliary` には分離できない。
    static func from(pos: String?) -> LcidRank {
        guard let pos, !pos.isEmpty else { return .unknown }
        if pos.hasPrefix("proper_noun") { return .properNoun }
        if pos.hasPrefix("noun") { return .noun }
        if pos == "adjective" || pos.hasPrefix("adjective/") { return .adjective }
        if pos == "particle" || pos.hasPrefix("particle/") { return .particle }
        if pos == "verb" || pos.hasPrefix("verb/") { return .verb }
        return .unknown
    }

    /// 履歴行のタイブレーカー用。`lcid` 欠落の長文は `longPhrase` に落とす。
    static func forHistory(output: String, lcid: Int?, pos: String?) -> LcidRank {
        if lcid == nil, output.count > historyLongPhraseThreshold { return .longPhrase }
        if let lcid { return from(lcid: lcid) }
        return from(pos: pos)
    }

    /// `forHistory` の長文判定閾値（文字数。`output.count` と比較）。
    static let historyLongPhraseThreshold = 10
}
