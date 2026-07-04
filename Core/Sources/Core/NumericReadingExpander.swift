import Foundation

/// UserReading（ユーザー打鍵由来の `composedHiragana`）を AzooKey 向け EngineReading へ補完する。
///
/// 先頭 ASCII 数字 + 日付単位サフィックス（がつ / にち / ねん 等）だけを対象とする。
/// マッチしない読みは `nil` を返し、呼び出し側が UserReading をそのまま渡す。
enum NumericReadingExpander {

    static func engineReading(for userReading: String) -> String? {
        guard let (digits, suffix) = parseLeadingAsciiDigitsAndSuffix(userReading),
              let n = Int(digits)
        else { return nil }

        switch normalizeDateSuffix(suffix) {
        case "がつ":
            guard let body = monthStem(for: n) else { return nil }
            return body + "がつ"
        case "にち":
            return dayReading(for: n)
        case "ねん":
            guard let body = yearStem(for: n) else { return nil }
            return body + "ねん"
        default:
            return nil
        }
    }

    // MARK: - Parse

    private static func parseLeadingAsciiDigitsAndSuffix(_ reading: String) -> (digits: String, suffix: String)? {
        var index = reading.startIndex
        var digits = ""
        while index < reading.endIndex {
            let ch = reading[index]
            guard ch.isASCII, ch.isNumber else { break }
            digits.append(ch)
            index = reading.index(after: index)
        }
        guard !digits.isEmpty, index < reading.endIndex else { return nil }
        return (digits, String(reading[index...]))
    }

    private static func normalizeDateSuffix(_ suffix: String) -> String {
        switch suffix {
        case "がつ", "げつ": return "がつ"
        case "にち", "じつ": return "にち"
        case "ねん": return "ねん"
        default: return suffix
        }
    }

    // MARK: - Month (1–12)

    private static func monthStem(for month: Int) -> String? {
        switch month {
        case 1: return "いち"
        case 2: return "に"
        case 3: return "さん"
        case 4: return "し"
        case 5: return "ご"
        case 6: return "ろく"
        case 7: return "しち"
        case 8: return "はち"
        case 9: return "く"
        case 10: return "じゅう"
        case 11: return "じゅういち"
        case 12: return "じゅうに"
        default: return nil
        }
    }

    // MARK: - Day (1–31, 暦日読み)

    private static func dayReading(for day: Int) -> String? {
        guard (1...31).contains(day) else { return nil }
        if let fixed = fixedDayReadings[day] { return fixed }
        if day >= 21 { return "にじゅう" + teenDayStem(day - 20) + "にち" }
        if day >= 11 { return "じゅう" + teenDayStem(day - 10) + "にち" }
        return nil
    }

    private static let fixedDayReadings: [Int: String] = [
        1: "ついたち",
        2: "ふつか",
        3: "みっか",
        4: "よっか",
        5: "いつか",
        6: "むいか",
        7: "なのか",
        8: "ようか",
        9: "ここのか",
        10: "とおか",
        14: "じゅうよっか",
        20: "はつか",
        24: "にじゅうよっか",
    ]

    private static func teenDayStem(_ n: Int) -> String {
        switch n {
        case 1: return "いち"
        case 2: return "に"
        case 3: return "さん"
        case 4: return "よっ"
        case 5: return "ご"
        case 6: return "ろく"
        case 7: return "しち"
        case 8: return "はち"
        case 9: return "く"
        default: return ""
        }
    }

    // MARK: - Year (1–9999)

    private static func yearStem(for year: Int) -> String? {
        japaneseIntegerReading(year)
    }

    /// 整数の音読み（年・助数なし）。`2026` → `にせんにじゅうろく`。
    private static func japaneseIntegerReading(_ n: Int) -> String? {
        guard (1...9999).contains(n) else { return nil }
        var parts: [String] = []
        var rest = n

        let thousands = rest / 1000
        if thousands > 0 {
            guard let word = thousandsWord(thousands) else { return nil }
            parts.append(word)
            rest %= 1000
        }

        let hundreds = rest / 100
        if hundreds > 0 {
            guard let word = hundredsWord(hundreds) else { return nil }
            parts.append(word)
            rest %= 100
        }

        if rest >= 10 {
            guard let word = tensWord(rest) else { return nil }
            parts.append(word)
        } else if rest > 0 {
            guard let digit = ones[rest] else { return nil }
            parts.append(digit)
        }

        return parts.isEmpty ? nil : parts.joined()
    }

    private static func tensWord(_ n: Int) -> String? {
        guard (10...99).contains(n) else { return nil }
        let ten = n / 10
        let one = n % 10
        if ten == 1 { return one == 0 ? "じゅう" : "じゅう" + (ones[one] ?? "") }
        let stem = tensStem(ten)
        guard !stem.isEmpty else { return nil }
        if one == 0 { return stem + "じゅう" }
        return stem + "じゅう" + (ones[one] ?? "")
    }

    private static func hundredsWord(_ hundreds: Int) -> String? {
        switch hundreds {
        case 1: return "ひゃく"
        case 2: return "にひゃく"
        case 3: return "さんびゃく"
        case 4: return "よんひゃく"
        case 5: return "ごひゃく"
        case 6: return "ろっぴゃく"
        case 7: return "ななひゃく"
        case 8: return "はっぴゃく"
        case 9: return "きゅうひゃく"
        default: return nil
        }
    }

    private static func thousandsWord(_ thousands: Int) -> String? {
        switch thousands {
        case 1: return "せん"
        case 2: return "にせん"
        case 3: return "さんぜん"
        case 4: return "よんせん"
        case 5: return "ごせん"
        case 6: return "ろっせん"
        case 7: return "ななせん"
        case 8: return "はっせん"
        case 9: return "きゅうせん"
        default: return nil
        }
    }

    private static let ones: [Int: String] = [
        1: "いち", 2: "に", 3: "さん", 4: "よん", 5: "ご",
        6: "ろく", 7: "なな", 8: "はち", 9: "きゅう",
    ]

    private static func tensStem(_ tens: Int) -> String {
        switch tens {
        case 2: return "に"
        case 3: return "さん"
        case 4: return "よん"
        case 5: return "ご"
        case 6: return "ろく"
        case 7: return "なな"
        case 8: return "はち"
        case 9: return "きゅう"
        default: return ""
        }
    }
}
