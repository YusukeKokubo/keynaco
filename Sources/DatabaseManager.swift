import Foundation
import SQLite3

final class DatabaseManager {
    static let shared = DatabaseManager()

    private var db: OpaquePointer?

    private init() {
        openDatabase()
        createTable()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - セットアップ

    private func openDatabase() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ykey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("history.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            NSLog("ykey: DB を開けませんでした: \(path)")
            return
        }
        NSLog("ykey: DB パス = \(path)")
    }

    private func createTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS history (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            input   TEXT    NOT NULL,
            output  TEXT    NOT NULL,
            count   INTEGER NOT NULL DEFAULT 1,
            used_at INTEGER NOT NULL,
            UNIQUE(input, output)
        );
        CREATE INDEX IF NOT EXISTS idx_input ON history(input);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
        seedIfEmpty()
    }

    private func seedIfEmpty() {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM history", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int(stmt, 0) == 0 else { return }

        let seeds = [
            ("he", "hello"), ("he", "help"), ("he", "heart"),
            ("th", "the"), ("th", "thanks"), ("th", "there"),
            ("go", "good"), ("go", "google"), ("go", "goodbye"),
        ]
        for (input, output) in seeds {
            record(input: input, output: output)
        }
        NSLog("ykey: seeded %d entries", seeds.count)
    }

    // MARK: - 検索

    /// input が prefix と完全一致するエントリを返す（count 降順）
    func fetchCandidates(prefix: String) -> [String] {
        let sql = """
        SELECT output FROM history
        WHERE input LIKE ? || '%'
        ORDER BY count DESC, used_at DESC
        LIMIT 20;
        """
        var stmt: OpaquePointer?
        var results: [String] = []

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, prefix, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: ptr))
            }
        }
        return results
    }

    // MARK: - 記録

    /// 変換確定時に履歴へ追記（同じ input/output ペアはカウントアップ）
    func record(input: String, output: String) {
        let sql = """
        INSERT INTO history (input, output, count, used_at)
        VALUES (?, ?, 1, ?)
        ON CONFLICT(input, output) DO UPDATE SET
            count   = count + 1,
            used_at = excluded.used_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let t = Int64(Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 1, input,  -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, output, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 3, t)
        sqlite3_step(stmt)
    }
}
