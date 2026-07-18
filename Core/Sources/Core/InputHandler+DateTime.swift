import Foundation

public extension InputHandler {
    /// 和語の月日読み（`なながつ`・`ついたち` 等）。相対日付（`きょう`）は含まない。
    static func isNumericStyleDateTimeReading(_ reading: String) -> Bool {
        monthReadingTable[reading] != nil || dayReadingTable[reading] != nil
    }

    static func generateDateTimeCandidates(for reading: String) -> [String] {
        // Calendar.current / Date() は日時読みのときだけ（PLAN260718）。
        guard isDateTimeCandidateReading(reading) else { return [] }
        let cal = Calendar.current
        let now = Date()
        switch reading {
        case "きょう":   return formatDate(now, cal: cal)
        case "きのう":   return formatDate(cal.date(byAdding: .day, value: -1, to: now)!, cal: cal)
        case "あした", "あす":
                         return formatDate(cal.date(byAdding: .day, value:  1, to: now)!, cal: cal)
        case "いま":     return formatTime(now, cal: cal)
        case "ことし":   return formatYear(now, cal: cal)
        case "きょねん": return formatYear(cal.date(byAdding: .year, value: -1, to: now)!, cal: cal)
        case "らいねん": return formatYear(cal.date(byAdding: .year, value:  1, to: now)!, cal: cal)
        case "こんげつ": return formatMonth(now, cal: cal)
        case "せんげつ": return formatMonth(cal.date(byAdding: .month, value: -1, to: now)!, cal: cal)
        case "らいげつ": return formatMonth(cal.date(byAdding: .month, value:  1, to: now)!, cal: cal)
        default:
            if let month = monthNumber(forHiraganaReading: reading) {
                var comps = cal.dateComponents([.year], from: now)
                comps.month = month
                comps.day = 1
                guard let date = cal.date(from: comps) else { return [] }
                return formatMonth(date, cal: cal)
            }
            if let day = dayNumber(forHiraganaReading: reading) {
                var comps = cal.dateComponents([.year, .month], from: now)
                comps.day = day
                guard let date = cal.date(from: comps) else { return [] }
                return formatDate(date, cal: cal)
            }
            return []
        }
    }

    /// `generateDateTimeCandidates` が非空になり得る読みか（Calendar 生成前の早期判定）。
    private static func isDateTimeCandidateReading(_ reading: String) -> Bool {
        switch reading {
        case "きょう", "きのう", "あした", "あす", "いま",
             "ことし", "きょねん", "らいねん",
             "こんげつ", "せんげつ", "らいげつ":
            return true
        default:
            return isNumericStyleDateTimeReading(reading)
        }
    }

    private static func monthNumber(forHiraganaReading reading: String) -> Int? {
        monthReadingTable[reading]
    }

    private static func dayNumber(forHiraganaReading reading: String) -> Int? {
        dayReadingTable[reading]
    }

    private static let monthReadingTable: [String: Int] = [
        "いちがつ": 1, "ひとつき": 1,
        "にがつ": 2, "ふたつき": 2,
        "さんがつ": 3, "みつき": 3,
        "しがつ": 4, "よつき": 4, "よんがつ": 4,
        "ごがつ": 5, "いつつき": 5,
        "ろくがつ": 6, "むつき": 6,
        "しちがつ": 7, "なながつ": 7, "ななつき": 7,
        "はちがつ": 8, "やつき": 8,
        "くがつ": 9, "ここのつき": 9,
        "じゅうがつ": 10,
        "じゅういちがつ": 11,
        "じゅうにがつ": 12,
    ]

    private static let dayReadingTable: [String: Int] = [
        "ついたち": 1,
        "ふつか": 2,
        "みっか": 3,
        "よっか": 4,
        "いつか": 5,
        "むいか": 6,
        "なのか": 7,
        "ようか": 8,
        "ここのか": 9,
        "とおか": 10,
        "じゅうよっか": 14,
        "はつか": 20,
        "にじゅうよっか": 24,
    ]

    private static func formatDate(_ date: Date, cal: Calendar) -> [String] {
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        let d = cal.component(.day, from: date)
        return [
            "\(y)年\(m)月\(d)日",
            "\(m)月\(d)日",
            String(format: "%04d-%02d-%02d", y, m, d),
            String(format: "%04d/%02d/%02d", y, m, d),
        ]
    }

    private static func formatTime(_ date: Date, cal: Calendar) -> [String] {
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        return [String(format: "%d:%02d", h, m)]
    }

    private static func formatYear(_ date: Date, cal: Calendar) -> [String] {
        let y = cal.component(.year, from: date)
        return ["\(y)年", "\(y)"]
    }

    private static func formatMonth(_ date: Date, cal: Calendar) -> [String] {
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        return ["\(y)年\(m)月", "\(m)月"]
    }
}
