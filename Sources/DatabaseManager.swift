import Foundation
import SQLite3

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private var db: OpaquePointer?

    private init() {
        openDatabase()
        createTables()
    }

    /// テスト用: インメモリ DB で初期化
    init(inMemory: Bool) {
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return }
        createTables()
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

    private func createTables() {
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
    }

    // MARK: - SQLite ヘルパー

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    // MARK: - 検索

    /// 読みに完全一致する履歴候補を使用頻度順で返す。
    func fetchHistoryExact(reading: String) -> [String] {
        let sql = "SELECT output FROM history WHERE input = ? ORDER BY count DESC, used_at DESC LIMIT 10"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bindText(stmt, 1, reading)
        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) { results.append(String(cString: ptr)) }
        }
        return results
    }

    // MARK: - 削除

    /// 履歴から指定の output を持つエントリを削除
    func deleteHistory(output: String) {
        let sql = "DELETE FROM history WHERE output = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, output)
        sqlite3_step(stmt)
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
        bindText(stmt, 1, input)
        bindText(stmt, 2, output)
        sqlite3_bind_int64(stmt, 3, t)
        sqlite3_step(stmt)
    }
}
