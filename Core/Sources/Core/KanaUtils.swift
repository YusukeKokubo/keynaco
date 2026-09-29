import Foundation

/// ひらがな・カタカナ・全角/半角 ASCII 間の変換ユーティリティ。
/// state を持たない pure な関数のみ。
enum KanaUtils {

    /// ひらがな（U+3041〜U+3096）かどうか。
    static func isHiragana(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0x3041 && scalar.value <= 0x3096
    }

    /// 全角カタカナ（U+30A1〜U+30F6）かどうか。
    static func isKatakana(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0x30A1 && scalar.value <= 0x30F6
    }

    /// CJK 統合漢字・拡張 A・々（AzooKey 残余フィルタと同じ範囲）。
    static func containsCJKIdeograph(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || scalar.value == 0x3005
        }
    }

/// 小書き仮名（拗音・促音以外の縮み仮名）。モーラ数カウントでは 1 モーラに含めない。
    private static let moraSmallKana: Set<Character> = [
        "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゃ", "ゅ", "ょ", "ゎ", "ゕ", "ゖ",
    ]

    /// ひらがな読みのモーラ数（小書き仮名を直前音に吸収。`っ` は 1 モーラ）。
    static func moraCount(in hiragana: String) -> Int {
        hiragana.reduce(into: 0) { count, ch in
            if !moraSmallKana.contains(ch) { count += 1 }
        }
    }

    /// 外来語にしか現れない拗音（和語・漢語の読みには出ない組み合わせ）。
    private static let loanwordOnlyMorae: [String] = [
        "ふぁ", "ふぃ", "ふぇ", "ふぉ", "ふゅ", "てぃ", "でぃ", "とぅ", "どぅ", "てゅ", "でゅ",
        "うぃ", "うぇ", "うぉ", "ゔ", "ちぇ", "しぇ", "じぇ",
        "つぁ", "つぃ", "つぇ", "つぉ", "くぁ", "ぐぁ",
    ]

    /// 読みが外来語らしいか（長音 `ー` か外来語専用の拗音を含む）。
    /// `すげー` / `わーっと` のような長音入りの和語も該当する（PLAN260929 で許容した誤判定）。
    static func hasLoanwordSignal(_ reading: String) -> Bool {
        reading.contains("ー") || loanwordOnlyMorae.contains { reading.contains($0) }
    }

    /// ひらがな → 全角カタカナ。U+3041〜U+3096 を +0x60 シフト。
    static func hiraganaToKatakana(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar in
            if scalar.value >= 0x3041 && scalar.value <= 0x3096 {
                return Character(UnicodeScalar(scalar.value + 0x60)!)
            }
            return Character(scalar)
        })
    }

    /// ひらがな → 半角カタカナ。濁音・半濁音は分解（"が" → "ｶﾞ"）。
    static func hiraganaToHankakuKatakana(_ text: String) -> String {
        text.map { hankakuMap[$0] ?? String($0) }.joined()
    }

    /// ASCII → 全角 ASCII（U+3000 / U+FF01〜U+FF5E）。F9 確定で使用。
    static func toZenkakuAscii(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar in
            if scalar.value == 0x20 {
                return Character(UnicodeScalar(0x3000)!)
            } else if scalar.value >= 0x21 && scalar.value <= 0x7E {
                return Character(UnicodeScalar(scalar.value + 0xFEE0)!)
            }
            return Character(scalar)
        })
    }

    private static let hankakuMap: [Character: String] = [
        "ぁ": "ｧ", "あ": "ｱ", "ぃ": "ｨ", "い": "ｲ", "ぅ": "ｩ", "う": "ｳ",
        "ぇ": "ｪ", "え": "ｴ", "ぉ": "ｫ", "お": "ｵ",
        "か": "ｶ", "が": "ｶﾞ", "き": "ｷ", "ぎ": "ｷﾞ", "く": "ｸ", "ぐ": "ｸﾞ",
        "け": "ｹ", "げ": "ｹﾞ", "こ": "ｺ", "ご": "ｺﾞ",
        "さ": "ｻ", "ざ": "ｻﾞ", "し": "ｼ", "じ": "ｼﾞ", "す": "ｽ", "ず": "ｽﾞ",
        "せ": "ｾ", "ぜ": "ｾﾞ", "そ": "ｿ", "ぞ": "ｿﾞ",
        "た": "ﾀ", "だ": "ﾀﾞ", "ち": "ﾁ", "ぢ": "ﾁﾞ", "っ": "ｯ", "つ": "ﾂ", "づ": "ﾂﾞ",
        "て": "ﾃ", "で": "ﾃﾞ", "と": "ﾄ", "ど": "ﾄﾞ",
        "な": "ﾅ", "に": "ﾆ", "ぬ": "ﾇ", "ね": "ﾈ", "の": "ﾉ",
        "は": "ﾊ", "ば": "ﾊﾞ", "ぱ": "ﾊﾟ", "ひ": "ﾋ", "び": "ﾋﾞ", "ぴ": "ﾋﾟ",
        "ふ": "ﾌ", "ぶ": "ﾌﾞ", "ぷ": "ﾌﾟ", "へ": "ﾍ", "べ": "ﾍﾞ", "ぺ": "ﾍﾟ",
        "ほ": "ﾎ", "ぼ": "ﾎﾞ", "ぽ": "ﾎﾟ",
        "ま": "ﾏ", "み": "ﾐ", "む": "ﾑ", "め": "ﾒ", "も": "ﾓ",
        "ゃ": "ｬ", "や": "ﾔ", "ゅ": "ｭ", "ゆ": "ﾕ", "ょ": "ｮ", "よ": "ﾖ",
        "ら": "ﾗ", "り": "ﾘ", "る": "ﾙ", "れ": "ﾚ", "ろ": "ﾛ",
        "わ": "ﾜ", "ゐ": "ｲ", "ゑ": "ｴ", "を": "ｦ",
        "ん": "ﾝ", "ー": "ｰ",
        "。": "｡", "「": "｢", "」": "｣", "、": "､", "・": "･",
    ]
}
