import Foundation

/// AzooKey 辞書の連接 ID（`lcid`）を keynaco の `pos` に変換する。
enum AzooKeyLcidMapper {
    /// 名詞・固有名詞のみ返す。動詞・形容詞等は keynaco 上の価値が低いため `nil`。
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
        default:
            return nil
        }
    }
}
