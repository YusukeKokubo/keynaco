import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// AzooKey 辞書の連接 ID（`lcid`）を keynaco の `pos` に変換する。
///
/// lcid レンジの根拠: AzooKey `DicdataStore`（助詞 147…368、助動詞 369…554）と
/// IPADic 系の接続 ID 帯。形容詞は 11…52、動詞は 53…1280（名詞帯を除く）。
enum AzooKeyLcidMapper {
    /// `lcid` から候補並び替えランクを返す。`classification(for:)` とは独立（助動詞は表示上 `verb` だが rank は `auxiliary`）。
    static func rank(for lcid: Int?) -> LcidRank {
        guard let lcid else { return .unknown }
        switch lcid {
        case 1288...1293:
            return .properNoun
        case 1281...1287, 1285, 1294, 1295, 1296, 1297...1305, 1314:
            return .noun
        case 11..<53:
            return .adjective
        default:
            break
        }
        if CIDData.isJoshi(cid: lcid) {
            return .particle
        }
        if (369...554).contains(lcid) {
            return .auxiliary
        }
        if (557...560).contains(lcid) {
            return .unknown
        }
        if (53..<1281).contains(lcid) {
            return .verb
        }
        return .unknown
    }

    static func classification(for lcid: Int) -> POSClassification? {
        switch lcid {
        case 1289, 1290, 1291:
            return POSClassification(pos: "proper_noun/person")
        case 1292:
            return POSClassification(pos: "proper_noun/org")
        case 1293:
            return POSClassification(pos: "proper_noun/place")
        case 1288:
            return POSClassification(pos: "proper_noun")
        case 1285, 1295:
            return POSClassification(pos: "noun")
        case 1281...1287, 1294, 1296:
            return POSClassification(pos: "noun")
        case 1297...1305:
            return POSClassification(pos: "noun/suffix")
        case 1314:
            // 副詞的名詞（「今」等）。AzooKey `INPOSITION_wordIDs` に含まれる。
            return POSClassification(pos: "noun")
        default:
            break
        }
        if CIDData.isJoshi(cid: lcid) {
            return POSClassification(pos: "particle")
        }
        if (369...554).contains(lcid) {
            return POSClassification(pos: "verb")
        }
        if (11..<53).contains(lcid) {
            return POSClassification(pos: "adjective")
        }
        if (557...560).contains(lcid) {
            return nil
        }
        if (53..<1281).contains(lcid) {
            return POSClassification(pos: "verb")
        }
        return nil
    }
}
