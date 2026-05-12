import Foundation
import SQLite3

public final class DatabaseManager: @unchecked Sendable {
    public static let shared = DatabaseManager()

    var db: OpaquePointer?
    var stmtCache: [String: OpaquePointer] = [:]
    let dbQueue = DispatchQueue(label: "keynaco.db", qos: .utility)
    // inMemory=true のテストでは書き込みを同期実行して即座に読み取れるようにする
    let writeAsync: Bool

    // τ = 30日: 30日経過で count の重みが半減するスケール
    static let recencyTauSeconds: Double = 30 * 86400
    // 時間減衰スコア式: 各クエリの ORDER BY / SUM で使用する
    static let recencyExpr = "count * 1.0 / (1.0 + (? - used_at) * 1.0 / ?)"
    var clock: () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    func nowEpoch() -> Int64 { clock() }

    /// `preset_seeded_v1` の保存先。統合テスト等で `UserDefaults(suiteName:)` に差し替え可能（既定は `standard`）。
    var presetSeedUserDefaults: UserDefaults = .standard

    private static let presetSeededUserDefaultsKey = "preset_seeded_v1"

    private init() {
        writeAsync = true
        openDatabase()
        createTables()
        ensureBigramIsPresetColumn()
        seedPresetBigramsIfNeeded()
    }

    /// テスト用: インメモリ DB で初期化
    /// - Parameter seedPresets: `true` のとき UserDefaults を踏まず `preset_bigram.csv` を投入（デバッグサンドボックス用）
    public init(inMemory: Bool, seedPresets: Bool = false) {
        writeAsync = false
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return }
        createTables()
        ensureBigramIsPresetColumn()
        if seedPresets { forceSeedPresets() }
    }

    /// デバッグ用: 既存ファイル DB を開く（一時スナップショット等）。`CREATE` は付けず、誤った空ファイル生成を避ける。
    public init(snapshotPath: String) {
        writeAsync = false
        guard sqlite3_open_v2(snapshotPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
        createTables()
        ensureBigramIsPresetColumn()
    }

    deinit {
        dbQueue.sync {
            for (_, stmt) in self.stmtCache { sqlite3_finalize(stmt) }
            sqlite3_close(self.db)
        }
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
        executeOnQueue("PRAGMA journal_mode = WAL;")
        executeOnQueue("PRAGMA synchronous = NORMAL;")
        executeOnQueue("PRAGMA cache_size = -4096;")
        #if DEBUG
        NSLog("keynaco: DB パス = \(path)")
        #endif
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
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            prev      TEXT    NOT NULL,
            input     TEXT    NOT NULL,
            output    TEXT    NOT NULL,
            count     INTEGER NOT NULL DEFAULT 1,
            used_at   INTEGER NOT NULL,
            is_preset INTEGER NOT NULL DEFAULT 0,
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
        CREATE TABLE IF NOT EXISTS user_dict (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            input   TEXT    NOT NULL,
            output  TEXT    NOT NULL,
            UNIQUE(input, output)
        );
        CREATE INDEX IF NOT EXISTS idx_user_dict ON user_dict(input);
        CREATE TABLE IF NOT EXISTS boundary_pref (
            full_reading  TEXT NOT NULL PRIMARY KEY,
            boundaries    TEXT NOT NULL,
            used_at       INTEGER NOT NULL
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func dispatchWrite(_ block: @escaping () -> Void) {
        if writeAsync { dbQueue.async(execute: block) } else { dbQueue.sync(execute: block) }
    }

    /// 既存 DB（is_preset 列がない）向け。新規 CREATE 済みの場合は duplicate column エラーで無視する。
    private func ensureBigramIsPresetColumn() {
        sqlite3_exec(
            db,
            "ALTER TABLE bigram ADD COLUMN is_preset INTEGER NOT NULL DEFAULT 0",
            nil, nil, nil
        )
    }

    /// バンドル内 `preset_bigram.csv` を初回のみ投入（`init(inMemory:)` では呼ばない）。
    private func seedPresetBigramsIfNeeded() {
        guard presetSeedUserDefaults.object(forKey: Self.presetSeededUserDefaultsKey) == nil else { return }
        forceSeedPresets()
        presetSeedUserDefaults.set(true, forKey: Self.presetSeededUserDefaultsKey)
    }

    /// UserDefaults チェックなしで `preset_bigram.csv` を投入する（デバッグサンドボックス専用）。
    private func forceSeedPresets() {
        guard let url = Bundle.main.url(forResource: "preset_bigram", withExtension: "csv") else {
            NSLog("keynaco: preset_bigram.csv がバンドルに含まれていません")
            return
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("keynaco: preset_bigram.csv を読めませんでした")
            return
        }
        let initialCount = Int64(LearningThresholds.successorImmediateThreshold)
        let t = nowEpoch()
        executeOnQueue("BEGIN")
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("prev,") { continue }
            let parts = trimmed.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count == 3 else { continue }
            let prev = parts[0], input = parts[1], output = parts[2]
            if prev.isEmpty || input.isEmpty || output.isEmpty { continue }
            executeOnQueue("""
            INSERT OR IGNORE INTO bigram (prev, input, output, count, used_at, is_preset)
            VALUES (?, ?, ?, ?, ?, 1)
            """) { stmt in
                self.bindText(stmt, 1, prev)
                self.bindText(stmt, 2, input)
                self.bindText(stmt, 3, output)
                sqlite3_bind_int64(stmt, 4, initialCount)
                sqlite3_bind_int64(stmt, 5, t)
            }
        }
        executeOnQueue("COMMIT")
    }

    // MARK: - SQLite ヘルパー（dbQueue 上でのみ呼び出す）

    func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    /// recencyExpr の `?` パラメータ（now, tau）を連続した2インデックスにバインドする。
    func bindRecency(_ stmt: OpaquePointer?, at index: Int32, now: Int64) {
        sqlite3_bind_int64(stmt, index, now)
        sqlite3_bind_double(stmt, index + 1, Self.recencyTauSeconds)
    }

    func cachedStmt(for sql: String) -> OpaquePointer? {
        if let cached = stmtCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            return nil
        }
        stmtCache[sql] = s
        return s
    }

    func queryStringsOnQueue(
        _ sql: String,
        bind: ((OpaquePointer?) -> Void)? = nil,
        columnIndex: Int32 = 0
    ) -> [String] {
        guard let stmt = cachedStmt(for: sql) else { return [] }
        bind?(stmt)
        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, columnIndex) { results.append(String(cString: ptr)) }
        }
        return results
    }

    func queryStringKindPairsOnQueue(
        _ sql: String,
        bind: ((OpaquePointer?) -> Void)? = nil
    ) -> [(output: String, kind: Int32)] {
        guard let stmt = cachedStmt(for: sql) else { return [] }
        bind?(stmt)
        var results: [(String, Int32)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) {
                results.append((String(cString: ptr), sqlite3_column_int(stmt, 1)))
            }
        }
        return results
    }

    func queryOutputScorePairsOnQueue(
        _ sql: String,
        bind: ((OpaquePointer?) -> Void)? = nil
    ) -> [(String, Double)] {
        guard let stmt = cachedStmt(for: sql) else { return [] }
        bind?(stmt)
        var results: [(String, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ptr = sqlite3_column_text(stmt, 0) else { continue }
            results.append((String(cString: ptr), sqlite3_column_double(stmt, 1)))
        }
        return results
    }

    func executeOnQueue(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil) {
        guard let stmt = cachedStmt(for: sql) else { return }
        bind?(stmt)
        sqlite3_step(stmt)
    }

    // MARK: - 設定画面用（型定義）

    public struct BigramEntry: Sendable {
        public let prev: String
        public let input: String
        public let output: String
        public let count: Int

        public init(prev: String, input: String, output: String, count: Int) {
            self.prev = prev
            self.input = input
            self.output = output
            self.count = count
        }
    }

    public struct TrigramEntry: Sendable {
        public let prev2: String
        public let prev1: String
        public let input: String
        public let output: String
        public let count: Int

        public init(prev2: String, prev1: String, input: String, output: String, count: Int) {
            self.prev2 = prev2
            self.prev1 = prev1
            self.input = input
            self.output = output
            self.count = count
        }
    }

    public struct HistoryEntry: Sendable {
        public let input: String
        public let output: String
        public let count: Int
    }

    public struct UserDictEntry: Sendable {
        public let id: Int
        public let input: String
        public let output: String
    }

    /// 確定直後 Backspace（誤変換訂正）で history / bigram / trigram / skip_bigram / boundary_pref を一括ペナルティする。
    func penalizeAll(
        input: String,
        output: String,
        prev1: String?,
        prev2: String?,
        skipPrevs: [String],
        fullReading: String?
    ) {
        dispatchWrite {
            self.executeOnQueue("BEGIN")
            self.executeOnQueue("UPDATE history SET count = count - 1 WHERE input = ? AND output = ?") {
                self.bindText($0, 1, input); self.bindText($0, 2, output)
            }
            self.executeOnQueue("DELETE FROM history WHERE input = ? AND output = ? AND count <= 0") {
                self.bindText($0, 1, input); self.bindText($0, 2, output)
            }
            if let p1 = prev1 {
                self.executeOnQueue("""
                    UPDATE bigram SET count = count - 1
                    WHERE prev = ? AND input = ? AND output = ? AND is_preset = 0
                    """) {
                    self.bindText($0, 1, p1); self.bindText($0, 2, input); self.bindText($0, 3, output)
                }
                self.executeOnQueue("""
                    DELETE FROM bigram
                    WHERE prev = ? AND input = ? AND output = ? AND count <= 0 AND is_preset = 0
                    """) {
                    self.bindText($0, 1, p1); self.bindText($0, 2, input); self.bindText($0, 3, output)
                }
            }
            if let p2 = prev2, let p1 = prev1 {
                self.executeOnQueue("""
                    UPDATE trigram SET count = count - 1
                    WHERE prev2 = ? AND prev1 = ? AND input = ? AND output = ?
                    """) {
                    self.bindText($0, 1, p2); self.bindText($0, 2, p1)
                    self.bindText($0, 3, input); self.bindText($0, 4, output)
                }
                self.executeOnQueue("""
                    DELETE FROM trigram
                    WHERE prev2 = ? AND prev1 = ? AND input = ? AND output = ? AND count <= 0
                    """) {
                    self.bindText($0, 1, p2); self.bindText($0, 2, p1)
                    self.bindText($0, 3, input); self.bindText($0, 4, output)
                }
            }
            for sp in skipPrevs {
                self.executeOnQueue("""
                    UPDATE skip_bigram SET count = count - 1
                    WHERE prev = ? AND input = ? AND output = ?
                    """) {
                    self.bindText($0, 1, sp); self.bindText($0, 2, input); self.bindText($0, 3, output)
                }
                self.executeOnQueue("""
                    DELETE FROM skip_bigram
                    WHERE prev = ? AND input = ? AND output = ? AND count <= 0
                    """) {
                    self.bindText($0, 1, sp); self.bindText($0, 2, input); self.bindText($0, 3, output)
                }
            }
            if let fr = fullReading {
                self.executeOnQueue("DELETE FROM boundary_pref WHERE full_reading = ?") {
                    self.bindText($0, 1, fr)
                }
            }
            self.executeOnQueue("COMMIT")
        }
    }

    // MARK: - GC

    public func performGCIfNeeded() {
        let key = "lastGCDate"
        let defaults = UserDefaults.standard
        let now = nowEpoch()
        if let lastEpoch = defaults.object(forKey: key) as? Int64,
           now - lastEpoch < 7 * 86400 { return }

        dispatchWrite {
            let cutoff = self.nowEpoch() - 180 * 86400
            let tables = ["history", "trigram", "skip_bigram"]
            for table in tables {
                self.executeOnQueue("DELETE FROM \(table) WHERE count = 1 AND used_at < ?") { stmt in
                    sqlite3_bind_int64(stmt, 1, cutoff)
                }
            }
            self.executeOnQueue(
                "DELETE FROM bigram WHERE count = 1 AND used_at < ? AND is_preset = 0"
            ) { sqlite3_bind_int64($0, 1, cutoff) }
            self.executeOnQueue("DELETE FROM boundary_pref WHERE used_at < ?") { sqlite3_bind_int64($0, 1, cutoff) }
            sqlite3_exec(self.db, "VACUUM;", nil, nil, nil)
            defaults.set(self.nowEpoch(), forKey: key)
            #if DEBUG
            NSLog("keynaco: DB GC 完了")
            #endif
        }
    }
}
