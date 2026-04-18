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
        CREATE TABLE IF NOT EXISTS bigram (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            prev    TEXT    NOT NULL,
            input   TEXT    NOT NULL,
            output  TEXT    NOT NULL,
            count   INTEGER NOT NULL DEFAULT 1,
            used_at INTEGER NOT NULL,
            UNIQUE(prev, input, output)
        );
        CREATE INDEX IF NOT EXISTS idx_bigram ON bigram(prev, input);
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

    /// 読みが前方一致する履歴候補を使用頻度順で返す（完全一致は除外）。
    func fetchHistoryPrefix(reading: String) -> [String] {
        let sql = "SELECT output FROM history WHERE input LIKE ? AND input != ? ORDER BY count DESC, used_at DESC LIMIT 10"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bindText(stmt, 1, reading + "%")
        bindText(stmt, 2, reading)
        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) { results.append(String(cString: ptr)) }
        }
        return results
    }

    // MARK: - 設定画面用

    struct BigramEntry {
        let prev: String
        let input: String
        let output: String
        let count: Int
    }

    struct HistoryEntry {
        let input: String
        let output: String
        let count: Int
    }

    func fetchAllBigram() -> [BigramEntry] {
        let sql = "SELECT prev, input, output, count FROM bigram ORDER BY count DESC, used_at DESC LIMIT 1000"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var results: [BigramEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let p = sqlite3_column_text(stmt, 0),
                  let i = sqlite3_column_text(stmt, 1),
                  let o = sqlite3_column_text(stmt, 2) else { continue }
            results.append(BigramEntry(
                prev: String(cString: p), input: String(cString: i),
                output: String(cString: o), count: Int(sqlite3_column_int(stmt, 3))
            ))
        }
        return results
    }

    func deleteBigram(prev: String, input: String, output: String) {
        let sql = "DELETE FROM bigram WHERE prev = ? AND input = ? AND output = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, prev); bindText(stmt, 2, input); bindText(stmt, 3, output)
        sqlite3_step(stmt)
    }

    func fetchAllHistory() -> [HistoryEntry] {
        let sql = "SELECT input, output, count FROM history ORDER BY count DESC, used_at DESC LIMIT 1000"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var results: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let i = sqlite3_column_text(stmt, 0),
                  let o = sqlite3_column_text(stmt, 1) else { continue }
            results.append(HistoryEntry(
                input: String(cString: i), output: String(cString: o),
                count: Int(sqlite3_column_int(stmt, 2))
            ))
        }
        return results
    }

    func deleteHistoryEntry(input: String, output: String) {
        let sql = "DELETE FROM history WHERE input = ? AND output = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, input); bindText(stmt, 2, output)
        sqlite3_step(stmt)
    }

    // MARK: - Bi-gram

    func recordBigram(prev: String, input: String, output: String) {
        let sql = """
        INSERT INTO bigram (prev, input, output, count, used_at)
        VALUES (?, ?, ?, 1, ?)
        ON CONFLICT(prev, input, output) DO UPDATE SET
            count   = count + 1,
            used_at = excluded.used_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let t = Int64(Date().timeIntervalSince1970)
        bindText(stmt, 1, prev)
        bindText(stmt, 2, input)
        bindText(stmt, 3, output)
        sqlite3_bind_int64(stmt, 4, t)
        sqlite3_step(stmt)
    }

    func fetchBigram(prev: String, reading: String) -> [String] {
        let sql = "SELECT output FROM bigram WHERE prev = ? AND input LIKE ? ORDER BY count DESC, used_at DESC LIMIT 10"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bindText(stmt, 1, prev)
        bindText(stmt, 2, reading + "%")
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
