import Foundation
import SQLite3

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private var db: OpaquePointer?

    // τ = 30日: 30日経過で count の重みが半減するスケール
    private static let recencyTauSeconds: Double = 30 * 86400
    var clock: () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    private func nowEpoch() -> Int64 { clock() }

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
            .appendingPathComponent("keynaco", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("history.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            NSLog("keynaco: DB を開けませんでした: \(path)")
            return
        }
        NSLog("keynaco: DB パス = \(path)")
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
        CREATE TABLE IF NOT EXISTS trigram (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            prev2   TEXT    NOT NULL,
            prev1   TEXT    NOT NULL,
            input   TEXT    NOT NULL,
            output  TEXT    NOT NULL,
            count   INTEGER NOT NULL DEFAULT 1,
            used_at INTEGER NOT NULL,
            UNIQUE(prev2, prev1, input, output)
        );
        CREATE INDEX IF NOT EXISTS idx_trigram ON trigram(prev2, prev1, input);
        CREATE TABLE IF NOT EXISTS skip_bigram (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            prev    TEXT    NOT NULL,
            input   TEXT    NOT NULL,
            output  TEXT    NOT NULL,
            count   INTEGER NOT NULL DEFAULT 1,
            used_at INTEGER NOT NULL,
            UNIQUE(prev, input, output)
        );
        CREATE INDEX IF NOT EXISTS idx_skip_bigram ON skip_bigram(prev, input);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - SQLite ヘルパー

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func queryStrings(
        _ sql: String,
        bind: ((OpaquePointer?) -> Void)? = nil,
        columnIndex: Int32 = 0
    ) -> [String] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bind?(stmt)
        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, columnIndex) { results.append(String(cString: ptr)) }
        }
        return results
    }

    private func execute(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        sqlite3_step(stmt)
    }

    // MARK: - 検索

    /// 読みに完全一致する履歴候補を使用頻度順で返す。
    func fetchHistoryExact(reading: String) -> [String] {
        let now = nowEpoch()
        return queryStrings("""
        SELECT output FROM history
        WHERE input = ? COLLATE NOCASE
        ORDER BY (count * 1.0 / (1.0 + (? - used_at) * 1.0 / ?)) DESC, used_at DESC
        LIMIT 10
        """) {
            self.bindText($0, 1, reading)
            sqlite3_bind_int64($0, 2, now)
            sqlite3_bind_double($0, 3, Self.recencyTauSeconds)
        }
    }

    /// 読みが前方一致する履歴候補を使用頻度順で返す（完全一致は除外）。
    func fetchHistoryPrefix(reading: String) -> [String] {
        let now = nowEpoch()
        return queryStrings("""
        SELECT output FROM history
        WHERE input LIKE ? AND input != ?
        ORDER BY (count * 1.0 / (1.0 + (? - used_at) * 1.0 / ?)) DESC, used_at DESC
        LIMIT 10
        """) {
            self.bindText($0, 1, reading + "%"); self.bindText($0, 2, reading)
            sqlite3_bind_int64($0, 3, now)
            sqlite3_bind_double($0, 4, Self.recencyTauSeconds)
        }
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
        execute("DELETE FROM bigram WHERE prev = ? AND input = ? AND output = ?") {
            self.bindText($0, 1, prev); self.bindText($0, 2, input); self.bindText($0, 3, output)
        }
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
        execute("DELETE FROM history WHERE input = ? AND output = ?") {
            self.bindText($0, 1, input); self.bindText($0, 2, output)
        }
    }

    /// 既存の bi-gram を全削除してからインポートデータで置き換える。
    func replaceBigram(_ entries: [BigramEntry]) {
        sqlite3_exec(db, "DELETE FROM bigram", nil, nil, nil)
        let sql = """
        INSERT INTO bigram (prev, input, output, count, used_at)
        VALUES (?, ?, ?, ?, ?)
        """
        let t = nowEpoch()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for entry in entries {
            bindText(stmt, 1, entry.prev); bindText(stmt, 2, entry.input)
            bindText(stmt, 3, entry.output)
            sqlite3_bind_int64(stmt, 4, Int64(entry.count))
            sqlite3_bind_int64(stmt, 5, t)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
    }

    // MARK: - Bi-gram

    func recordBigram(prev: String, input: String, output: String) {
        let t = nowEpoch()
        execute("""
        INSERT INTO bigram (prev, input, output, count, used_at)
        VALUES (?, ?, ?, 1, ?)
        ON CONFLICT(prev, input, output) DO UPDATE SET
            count   = count + 1,
            used_at = excluded.used_at;
        """) {
            self.bindText($0, 1, prev); self.bindText($0, 2, input); self.bindText($0, 3, output)
            sqlite3_bind_int64($0, 4, t)
        }
    }

    func fetchBigram(prev: String, reading: String) -> [String] {
        let now = nowEpoch()
        return queryStrings("""
        SELECT output FROM bigram
        WHERE prev = ? AND input LIKE ?
        ORDER BY (count * 1.0 / (1.0 + (? - used_at) * 1.0 / ?)) DESC, used_at DESC
        LIMIT 10
        """) {
            self.bindText($0, 1, prev); self.bindText($0, 2, reading + "%")
            sqlite3_bind_int64($0, 3, now)
            sqlite3_bind_double($0, 4, Self.recencyTauSeconds)
        }
    }

    /// prev に続く bi-gram 上位候補を返す（input に依らず output を集約）。
    /// 同じ output が複数 input で学習されている場合は count の合計でソートする。
    func fetchBigramTop(prev: String, limit: Int = 20) -> [String] {
        let now = nowEpoch()
        return queryStrings("""
        SELECT output FROM bigram
        WHERE prev = ?
        GROUP BY output
        ORDER BY SUM(count * 1.0 / (1.0 + (? - used_at) * 1.0 / ?)) DESC, MAX(used_at) DESC
        LIMIT ?
        """) {
            self.bindText($0, 1, prev)
            sqlite3_bind_int64($0, 2, now)
            sqlite3_bind_double($0, 3, Self.recencyTauSeconds)
            sqlite3_bind_int($0, 4, Int32(limit))
        }
    }

    /// prev に続く bi-gram の直近 90 日以内の最大 count を返す。即時表示の閾値判定用。
    func fetchBigramTopCount(prev: String) -> Int {
        let cutoff = nowEpoch() - 90 * 86400
        var stmt: OpaquePointer?
        let sql = "SELECT MAX(count) FROM bigram WHERE prev = ? AND used_at > ?"
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        bindText(stmt, 1, prev)
        sqlite3_bind_int64(stmt, 2, cutoff)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// list 内の候補を bi-gram 頻度順で返す（未登録分は除外）。
    func fetchBigramInList(prev: String, list: [String]) -> [String] {
        guard !list.isEmpty else { return [] }
        let now = nowEpoch()
        let placeholders = list.map { _ in "?" }.joined(separator: ",")
        return queryStrings("""
        SELECT output FROM bigram
        WHERE prev = ? AND output IN (\(placeholders))
        ORDER BY (count * 1.0 / (1.0 + (? - used_at) * 1.0 / ?)) DESC, used_at DESC
        """) {
            self.bindText($0, 1, prev)
            for (i, item) in list.enumerated() { self.bindText($0, Int32(i + 2), item) }
            sqlite3_bind_int64($0, Int32(list.count + 2), now)
            sqlite3_bind_double($0, Int32(list.count + 3), Self.recencyTauSeconds)
        }
    }

    // MARK: - Tri-gram

    func recordTrigram(prev2: String, prev1: String, input: String, output: String) {
        let t = nowEpoch()
        execute("""
        INSERT INTO trigram (prev2, prev1, input, output, count, used_at)
        VALUES (?, ?, ?, ?, 1, ?)
        ON CONFLICT(prev2, prev1, input, output) DO UPDATE SET
            count   = count + 1,
            used_at = excluded.used_at;
        """) {
            self.bindText($0, 1, prev2); self.bindText($0, 2, prev1)
            self.bindText($0, 3, input); self.bindText($0, 4, output)
            sqlite3_bind_int64($0, 5, t)
        }
    }

    func fetchTrigram(prev2: String, prev1: String, reading: String) -> [String] {
        let now = nowEpoch()
        return queryStrings("""
        SELECT output FROM trigram
        WHERE prev2 = ? AND prev1 = ? AND input LIKE ?
        ORDER BY (count * 1.0 / (1.0 + (? - used_at) * 1.0 / ?)) DESC, used_at DESC
        LIMIT 10
        """) {
            self.bindText($0, 1, prev2); self.bindText($0, 2, prev1); self.bindText($0, 3, reading + "%")
            sqlite3_bind_int64($0, 4, now)
            sqlite3_bind_double($0, 5, Self.recencyTauSeconds)
        }
    }

    func fetchTrigramTop(prev2: String, prev1: String, limit: Int = 20) -> [String] {
        let now = nowEpoch()
        return queryStrings("""
        SELECT output FROM trigram
        WHERE prev2 = ? AND prev1 = ?
        GROUP BY output
        ORDER BY SUM(count * 1.0 / (1.0 + (? - used_at) * 1.0 / ?)) DESC, MAX(used_at) DESC
        LIMIT ?
        """) {
            self.bindText($0, 1, prev2); self.bindText($0, 2, prev1)
            sqlite3_bind_int64($0, 3, now)
            sqlite3_bind_double($0, 4, Self.recencyTauSeconds)
            sqlite3_bind_int($0, 5, Int32(limit))
        }
    }

    func fetchTrigramInList(prev2: String, prev1: String, list: [String]) -> [String] {
        guard !list.isEmpty else { return [] }
        let now = nowEpoch()
        let placeholders = list.map { _ in "?" }.joined(separator: ",")
        return queryStrings("""
        SELECT output FROM trigram
        WHERE prev2 = ? AND prev1 = ? AND output IN (\(placeholders))
        ORDER BY (count * 1.0 / (1.0 + (? - used_at) * 1.0 / ?)) DESC, used_at DESC
        """) {
            self.bindText($0, 1, prev2); self.bindText($0, 2, prev1)
            for (i, item) in list.enumerated() { self.bindText($0, Int32(i + 3), item) }
            sqlite3_bind_int64($0, Int32(list.count + 3), now)
            sqlite3_bind_double($0, Int32(list.count + 4), Self.recencyTauSeconds)
        }
    }

    // MARK: - Skip-Bigram

    func recordSkipBigram(prev: String, input: String, output: String) {
        let t = nowEpoch()
        execute("""
        INSERT INTO skip_bigram (prev, input, output, count, used_at)
        VALUES (?, ?, ?, 1, ?)
        ON CONFLICT(prev, input, output) DO UPDATE SET
            count   = count + 1,
            used_at = excluded.used_at;
        """) {
            self.bindText($0, 1, prev); self.bindText($0, 2, input); self.bindText($0, 3, output)
            sqlite3_bind_int64($0, 4, t)
        }
    }

    func fetchSkipBigram(prev: String, reading: String) -> [String] {
        let now = nowEpoch()
        return queryStrings("""
        SELECT output FROM skip_bigram
        WHERE prev = ? AND input LIKE ?
        ORDER BY (count * 1.0 / (1.0 + (? - used_at) * 1.0 / ?)) DESC, used_at DESC
        LIMIT 10
        """) {
            self.bindText($0, 1, prev); self.bindText($0, 2, reading + "%")
            sqlite3_bind_int64($0, 3, now)
            sqlite3_bind_double($0, 4, Self.recencyTauSeconds)
        }
    }

    func fetchSkipBigramTop(prev: String, limit: Int = 20) -> [String] {
        let now = nowEpoch()
        return queryStrings("""
        SELECT output FROM skip_bigram
        WHERE prev = ?
        GROUP BY output
        ORDER BY SUM(count * 1.0 / (1.0 + (? - used_at) * 1.0 / ?)) DESC, MAX(used_at) DESC
        LIMIT ?
        """) {
            self.bindText($0, 1, prev)
            sqlite3_bind_int64($0, 2, now)
            sqlite3_bind_double($0, 3, Self.recencyTauSeconds)
            sqlite3_bind_int($0, 4, Int32(limit))
        }
    }

    // MARK: - 削除

    /// 履歴から指定の output を持つエントリを削除
    func deleteHistory(output: String) {
        execute("DELETE FROM history WHERE output = ?") { self.bindText($0, 1, output) }
    }

    // MARK: - 記録

    /// 変換確定時に履歴へ追記（同じ input/output ペアはカウントアップ）
    func record(input: String, output: String) {
        let t = nowEpoch()
        execute("""
        INSERT INTO history (input, output, count, used_at)
        VALUES (?, ?, 1, ?)
        ON CONFLICT(input, output) DO UPDATE SET
            count   = count + 1,
            used_at = excluded.used_at;
        """) {
            self.bindText($0, 1, input); self.bindText($0, 2, output)
            sqlite3_bind_int64($0, 3, t)
        }
    }

    /// フル読みに加え、先頭 2〜(N-1) 文字の各 prefix でも record する。
    /// 読みが ASCII のみ、または 5 文字未満の場合はフル読みのみ。
    func recordPrefixes(reading: String, output: String) {
        record(input: reading, output: output)
        guard !reading.allSatisfy({ $0.isASCII }) else { return }
        let chars = Array(reading)
        guard chars.count >= 3 else { return }
        for len in 2..<chars.count {
            record(input: String(chars.prefix(len)), output: output)
        }
    }
}
