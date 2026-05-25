import Foundation

/// AzooKey 辞書（`lcid`）＋接続詞/感動詞辞書による品詞分類。
public enum AzooKeyPOSClassifier {
    public static func classify(
        output: String,
        reading: String,
        converter: AzooKeyConverting
    ) -> POSClassification? {
        if Self.conjunctions.contains(output) {
            return POSClassification(pos: "other/conjunction", posTag: "other/conjunction", posRetry: false)
        }
        if Self.interjections.contains(output) {
            return POSClassification(pos: "other/interjection", posTag: "other/interjection", posRetry: false)
        }
        guard !reading.isEmpty,
              let lcid = converter.lcidForCommitted(reading: reading, output: output) else {
            return nil
        }
        return AzooKeyLcidMapper.classification(for: lcid)
    }

    private static let conjunctions: Set<String> = [
        "しかし", "ただし", "そして", "また", "または", "もしくは", "けれど", "けれども",
        "だが", "しかも", "なお", "つまり", "すなわち", "ところが", "それで", "それに",
        "そのため", "したがって", "ゆえに", "一方", "他方", "ならびに", "および",
    ]

    private static let interjections: Set<String> = [
        "ええっと", "えーっと", "あの", "あのう", "まあ", "うーん", "うん", "はあ", "ふう",
        "おっ", "よし", "おい", "ねえ", "へえ", "ほら", "さあ", "ちょっと",
    ]
}
