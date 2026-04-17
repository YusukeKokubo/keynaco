import Foundation
import SQLite3

enum DictionaryImporter {

    /// 辞書インポートのバージョン。SKK → mozc システム辞書に切り替えで 8 に上げる。
    private static let currentVersion = 8

    /// mozc-dict.sqlite をバンドルから ATTACH し、dictionary テーブルに一括転送する。
    static func importIfNeeded(db: OpaquePointer?) {
        guard let db = db else { return }

        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)", nil, nil, nil)
        var version = 0
        var vStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'dict_version'", -1, &vStmt, nil) == SQLITE_OK {
            if sqlite3_step(vStmt) == SQLITE_ROW { version = Int(sqlite3_column_int(vStmt, 0)) }
        }
        sqlite3_finalize(vStmt)
        guard version < currentVersion else { return }

        guard let bundledPath = Bundle.main.path(forResource: "mozc-dict", ofType: "sqlite") else {
            NSLog("ykey: mozc-dict.sqlite が見つかりません")
            return
        }

        let attachSQL = "ATTACH DATABASE '\(bundledPath)' AS mozc"
        guard sqlite3_exec(db, attachSQL, nil, nil, nil) == SQLITE_OK else {
            NSLog("ykey: mozc-dict.sqlite の ATTACH に失敗しました")
            return
        }
        defer { sqlite3_exec(db, "DETACH DATABASE mozc", nil, nil, nil) }

        NSLog("ykey: 辞書インポート開始")
        let start = CFAbsoluteTimeGetCurrent()

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM dictionary", nil, nil, nil)
        let result = sqlite3_exec(db,
            "INSERT OR IGNORE INTO dictionary (reading, candidate, priority) SELECT reading, candidate, priority FROM mozc.dictionary",
            nil, nil, nil)
        if result == SQLITE_OK {
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        } else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            NSLog("ykey: 辞書インポート失敗 — error code %d", result)
            return
        }

        sqlite3_exec(db, "INSERT OR REPLACE INTO meta (key, value) VALUES ('dict_version', \(currentVersion))", nil, nil, nil)

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        NSLog("ykey: 辞書インポート完了 — %.2f秒", elapsed)
    }
}
