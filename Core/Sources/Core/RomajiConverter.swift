import Foundation

public struct RomajiConverter {

    // MARK: - 変換テーブル

    private static let table: [String: String] = [
        // 母音
        "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",

        // か行
        "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",

        // さ行
        "sa": "さ", "si": "し", "su": "す", "se": "せ", "so": "そ",
        "shi": "し",

        // た行
        "ta": "た", "ti": "ち", "tu": "つ", "te": "て", "to": "と",
        "chi": "ち", "tsu": "つ",
        "thi": "てぃ", "thu": "てゅ",
        "tsa": "つぁ", "tse": "つぇ", "tso": "つぉ",

        // な行
        "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",

        // は行
        "ha": "は", "hi": "ひ", "hu": "ふ", "he": "へ", "ho": "ほ",
        "fu": "ふ",

        // ま行
        "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",

        // や行
        "ya": "や", "yu": "ゆ", "yo": "よ",

        // ら行
        "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",

        // わ行
        "wa": "わ", "wi": "うぃ", "we": "うぇ", "wo": "を", "who": "うぉ",

        // ん
        "xn": "ん",

        // が行
        "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",

        // ざ行
        "za": "ざ", "zi": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
        "ji": "じ",

        // だ行
        "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
        "dhi": "でぃ", "dhu": "でゅ",

        // ば行
        "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",

        // ぱ行
        "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",

        // きゃ行
        "kya": "きゃ", "kyi": "きぃ", "kyu": "きゅ", "kye": "きぇ", "kyo": "きょ",

        // しゃ行
        "sha": "しゃ", "shu": "しゅ", "she": "しぇ", "sho": "しょ",
        "sya": "しゃ", "syi": "しぃ", "syu": "しゅ", "sye": "しぇ", "syo": "しょ",

        // ちゃ行
        "cha": "ちゃ", "chu": "ちゅ", "che": "ちぇ", "cho": "ちょ",
        "tya": "ちゃ", "tyi": "ちぃ", "tyu": "ちゅ", "tye": "ちぇ", "tyo": "ちょ",

        // にゃ行
        "nya": "にゃ", "nyi": "にぃ", "nyu": "にゅ", "nye": "にぇ", "nyo": "にょ",

        // ひゃ行
        "hya": "ひゃ", "hyi": "ひぃ", "hyu": "ひゅ", "hye": "ひぇ", "hyo": "ひょ",

        // みゃ行
        "mya": "みゃ", "myi": "みぃ", "myu": "みゅ", "mye": "みぇ", "myo": "みょ",

        // りゃ行
        "rya": "りゃ", "ryi": "りぃ", "ryu": "りゅ", "rye": "りぇ", "ryo": "りょ",

        // ぎゃ行
        "gya": "ぎゃ", "gyi": "ぎぃ", "gyu": "ぎゅ", "gye": "ぎぇ", "gyo": "ぎょ",

        // じゃ行
        "ja": "じゃ", "ju": "じゅ", "je": "じぇ", "jo": "じょ",
        "jya": "じゃ", "jyi": "じぃ", "jyu": "じゅ", "jye": "じぇ", "jyo": "じょ",
        "zya": "じゃ", "zyi": "じぃ", "zyu": "じゅ", "zye": "じぇ", "zyo": "じょ",

        // びゃ行
        "bya": "びゃ", "byi": "びぃ", "byu": "びゅ", "bye": "びぇ", "byo": "びょ",

        // ぴゃ行
        "pya": "ぴゃ", "pyi": "ぴぃ", "pyu": "ぴゅ", "pye": "ぴぇ", "pyo": "ぴょ",

        // ふぁ行
        "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",

        // ゔ行
        "va": "ゔぁ", "vi": "ゔぃ", "vu": "ゔ", "ve": "ゔぇ", "vo": "ゔぉ",

        // ぢゃ行
        "dya": "ぢゃ", "dyi": "ぢぃ", "dyu": "ぢゅ", "dye": "ぢぇ", "dyo": "ぢょ",

        // 小文字
        "xa": "ぁ", "xi": "ぃ", "xu": "ぅ", "xe": "ぇ", "xo": "ぉ",
        "xya": "ゃ", "xyu": "ゅ", "xyo": "ょ",
        "xtu": "っ", "xtsu": "っ",

        // 記号
        "-": "ー",
    ]

    /// テーブルのキーの prefix になりうる文字列を事前計算
    private static let prefixes: Set<String> = {
        var set = Set<String>()
        for key in table.keys {
            for i in 1...key.count {
                set.insert(String(key.prefix(i)))
            }
        }
        return set
    }()

    /// 二重子音で「っ」になる子音
    private static let consonantsForSokuon: Set<Character> = [
        "b", "c", "d", "f", "g", "h", "j", "k", "m", "p", "r", "s", "t", "v", "w", "z",
    ]

    /// "n" の後に来ると「ん」にならない文字（母音 + y）
    private static let nExceptions: Set<Character> = ["a", "i", "u", "e", "o", "y"]

    // MARK: - 変換

    /// ローマ字文字列を変換する。
    /// - Returns: `converted` は確定済みひらがな、`pending` は未確定のローマ字
    public static func convert(_ romaji: String) -> (converted: String, pending: String) {
        var converted = ""
        var remaining = romaji.lowercased()

        while !remaining.isEmpty {
            // 二重子音 → っ
            if remaining.count >= 2 {
                let first = remaining[remaining.startIndex]
                let second = remaining[remaining.index(after: remaining.startIndex)]
                if first == second && consonantsForSokuon.contains(first) {
                    converted += "っ"
                    remaining.removeFirst()
                    continue
                }
            }

            // "n" + 子音(y,n以外) → ん
            if remaining.count >= 2 {
                let first = remaining[remaining.startIndex]
                let second = remaining[remaining.index(after: remaining.startIndex)]
                if first == "n" && !nExceptions.contains(second) {
                    converted += "ん"
                    remaining.removeFirst()
                    continue
                }
            }

            // 最長一致（4→3→2→1文字）
            var matched = false
            let maxLen = min(4, remaining.count)
            for len in stride(from: maxLen, through: 1, by: -1) {
                let candidate = String(remaining.prefix(len))
                if let hiragana = table[candidate] {
                    converted += hiragana
                    remaining.removeFirst(len)
                    matched = true
                    break
                }
            }
            if matched { continue }

            // テーブルの prefix に一致する場合は pending として残す
            if prefixes.contains(remaining) {
                return (converted, remaining)
            }

            // prefix の最長一致を探す
            let maxPrefixLen = min(4, remaining.count)
            for len in stride(from: maxPrefixLen, through: 1, by: -1) {
                let candidate = String(remaining.prefix(len))
                if prefixes.contains(candidate) {
                    return (converted, remaining)
                }
            }

            // どのテーブルエントリの prefix にもならない → そのまま出力
            converted += String(remaining.removeFirst())
        }

        return (converted, "")
    }

    /// ひらがな文字列をローマ字（半角ASCII）に変換する。F9/F10 確定で使用。
    public static func hiraganaToRomaji(_ text: String) -> String {
        let compound: [String: String] = [
            "きゃ": "kya", "きぃ": "kyi", "きゅ": "kyu", "きぇ": "kye", "きょ": "kyo",
            "しゃ": "sha", "しぃ": "syi", "しゅ": "shu", "しぇ": "she", "しょ": "sho",
            "ちゃ": "cha", "ちぃ": "tyi", "ちゅ": "chu", "ちぇ": "che", "ちょ": "cho",
            "にゃ": "nya", "にぃ": "nyi", "にゅ": "nyu", "にぇ": "nye", "にょ": "nyo",
            "ひゃ": "hya", "ひぃ": "hyi", "ひゅ": "hyu", "ひぇ": "hye", "ひょ": "hyo",
            "みゃ": "mya", "みぃ": "myi", "みゅ": "myu", "みぇ": "mye", "みょ": "myo",
            "りゃ": "rya", "りぃ": "ryi", "りゅ": "ryu", "りぇ": "rye", "りょ": "ryo",
            "ぎゃ": "gya", "ぎぃ": "gyi", "ぎゅ": "gyu", "ぎぇ": "gye", "ぎょ": "gyo",
            "じゃ": "ja",  "じぃ": "jyi", "じゅ": "ju",  "じぇ": "je",  "じょ": "jo",
            "びゃ": "bya", "びぃ": "byi", "びゅ": "byu", "びぇ": "bye", "びょ": "byo",
            "ぴゃ": "pya", "ぴぃ": "pyi", "ぴゅ": "pyu", "ぴぇ": "pye", "ぴょ": "pyo",
            "ふぁ": "fa",  "ふぃ": "fi",  "ふぇ": "fe",  "ふぉ": "fo",
            "ぢゃ": "dya", "ぢぃ": "dyi", "ぢゅ": "dyu", "ぢぇ": "dye", "ぢょ": "dyo",
        ]
        let single: [Character: String] = [
            "あ": "a",   "い": "i",   "う": "u",   "え": "e",   "お": "o",
            "か": "ka",  "き": "ki",  "く": "ku",  "け": "ke",  "こ": "ko",
            "さ": "sa",  "し": "shi", "す": "su",  "せ": "se",  "そ": "so",
            "た": "ta",  "ち": "chi", "つ": "tsu", "て": "te",  "と": "to",
            "な": "na",  "に": "ni",  "ぬ": "nu",  "ね": "ne",  "の": "no",
            "は": "ha",  "ひ": "hi",  "ふ": "fu",  "へ": "he",  "ほ": "ho",
            "ま": "ma",  "み": "mi",  "む": "mu",  "め": "me",  "も": "mo",
            "や": "ya",  "ゆ": "yu",  "よ": "yo",
            "ら": "ra",  "り": "ri",  "る": "ru",  "れ": "re",  "ろ": "ro",
            "わ": "wa",  "ゐ": "wi",  "ゑ": "we",  "を": "wo",  "ん": "n",
            "が": "ga",  "ぎ": "gi",  "ぐ": "gu",  "げ": "ge",  "ご": "go",
            "ざ": "za",  "じ": "ji",  "ず": "zu",  "ぜ": "ze",  "ぞ": "zo",
            "だ": "da",  "ぢ": "di",  "づ": "du",  "で": "de",  "ど": "do",
            "ば": "ba",  "び": "bi",  "ぶ": "bu",  "べ": "be",  "ぼ": "bo",
            "ぱ": "pa",  "ぴ": "pi",  "ぷ": "pu",  "ぺ": "pe",  "ぽ": "po",
            "ぁ": "xa",  "ぃ": "xi",  "ぅ": "xu",  "ぇ": "xe",  "ぉ": "xo",
            "ゃ": "xya", "ゅ": "xyu", "ょ": "xyo", "っ": "xtu",
            "ー": "-",
        ]
        let vowels: Set<Character> = ["a", "i", "u", "e", "o"]
        var result = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            // っ: 次の子音を重ねる
            if c == "っ" {
                let nextIdx = i + 1
                if nextIdx < chars.count {
                    let nextRomaji: String
                    if nextIdx + 1 < chars.count,
                       let comp = compound[String([chars[nextIdx], chars[nextIdx + 1]])] {
                        nextRomaji = comp
                    } else {
                        nextRomaji = single[chars[nextIdx]] ?? String(chars[nextIdx])
                    }
                    if let first = nextRomaji.first, !vowels.contains(first) {
                        result += String(first); i += 1; continue
                    }
                }
                result += "xtu"; i += 1; continue
            }
            // ん: 次が母音なら nn
            if c == "ん" {
                let nextIdx = i + 1
                if nextIdx < chars.count {
                    let nextRomaji = single[chars[nextIdx]] ?? String(chars[nextIdx])
                    if let first = nextRomaji.first, vowels.contains(first) {
                        result += "nn"; i += 1; continue
                    }
                }
                result += "n"; i += 1; continue
            }
            // 2文字複合（拗音等）
            if i + 1 < chars.count, let comp = compound[String([c, chars[i + 1]])] {
                result += comp; i += 2; continue
            }
            // 単体
            result += single[c] ?? String(c); i += 1
        }
        return result
    }

    /// 確定時に pending のローマ字を強制変換する。"n" → "ん" 等。
    public static func forceFinalize(_ pending: String) -> String {
        if pending.isEmpty { return "" }
        if pending == "n" { return "ん" }
        // pending が変換テーブルに完全一致する場合
        if let hiragana = table[pending.lowercased()] {
            return hiragana
        }
        // それ以外はそのまま返す
        return pending
    }
}
