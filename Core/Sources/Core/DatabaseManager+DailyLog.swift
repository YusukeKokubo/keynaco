import Foundation
import SQLite3

extension DatabaseManager {
    // MARK: - daily_log テーブル操作

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

    static func todayDateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    static func dateString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

}
