import Foundation
import SQLite3

extension DatabaseManager {
    // MARK: - daily_log テーブル操作

    public struct DailyLogEntry: Sendable {
        public let text: String
        public let appBundleID: String?
        public let createdAt: Int64
    }

    /// 確定テキストを daily_log に追記する。punctuation 除外は呼び出し側で行う。
    func recordDailyLog(output: String, appBundleID: String? = nil) {
        let date = Self.todayDateString()
        let now = nowEpoch()
        dispatchWrite {
            self.executeOnQueue("""
            INSERT INTO daily_log (date, committed_text, app_bundle_id, created_at) VALUES (?, ?, ?, ?)
            """) {
                self.bindText($0, 1, date)
                self.bindText($0, 2, output)
                if let bundleID = appBundleID {
                    self.bindText($0, 3, bundleID)
                } else {
                    sqlite3_bind_null($0, 3)
                }
                sqlite3_bind_int64($0, 4, now)
            }
        }
    }

    /// 指定日の確定テキストを時系列順（初出順）で返す。同一テキストは重複排除。
    public func fetchDailyLog(for date: String) -> [DailyLogEntry] {
        dbQueue.sync {
            let sql = """
            SELECT committed_text, app_bundle_id, MIN(created_at) AS first_seen
            FROM daily_log WHERE date = ?
            GROUP BY committed_text
            ORDER BY first_seen
            """
            guard let stmt = self.prepareUncachedStmt(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            self.bindText(stmt, 1, date)
            var results: [DailyLogEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let p = sqlite3_column_text(stmt, 0) else { continue }
                let text = String(cString: p)
                let appBundleID = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let createdAt = sqlite3_column_int64(stmt, 2)
                results.append(DailyLogEntry(text: text, appBundleID: appBundleID, createdAt: createdAt))
            }
            return results
        }
    }

    /// 指定日の daily_log エントリ数を返す。
    public func countDailyLog(for date: String) -> Int {
        dbQueue.sync {
            let sql = "SELECT COUNT(*) FROM daily_log WHERE date = ?"
            guard let stmt = self.prepareUncachedStmt(sql) else { return 0 }
            defer { sqlite3_finalize(stmt) }
            self.bindText(stmt, 1, date)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    static func todayDateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    public static func dateString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

}
