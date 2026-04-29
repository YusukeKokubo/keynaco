import Foundation

extension InputHandler {
    static func generateDateTimeCandidates(for reading: String) -> [String] {
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
        default: return []
        }
    }

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
