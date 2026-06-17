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

    private static let hiraganaPreferredSeededKey = "hiragana_preferred_seeded_v1"
    static let schemaVersionLatest = 5

    private enum SchemaMigration: Int, CaseIterable {
        case dropDeprecatedNgramTables = 1
        case ensureHistoryPOSColumn = 2
        case dropDeprecatedHistoryColumns = 3
        case ensureDailyLogAppColumn = 4
        case ensureHistoryLcidColumn = 5
    }

    private init() {
        writeAsync = true
        openDatabase()
        createTables()
        runMigrations()
        seedHiraganaPreferredIfNeeded()
    }

    /// テスト用: インメモリ DB で初期化
    public init(inMemory: Bool) {
        writeAsync = false
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return }
        createTables()
        runMigrations()
    }

    /// デバッグ用: 既存ファイル DB を開く（一時スナップショット等）。`CREATE` は付けず、誤った空ファイル生成を避ける。
    public init(snapshotPath: String) {
        writeAsync = false
        guard sqlite3_open_v2(snapshotPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
        createTables()
        runMigrations()
    }

    deinit {
        dbQueue.sync {
            for (_, stmt) in self.stmtCache { sqlite3_finalize(stmt) }
            sqlite3_close(self.db)
        }
    }

    // MARK: - セットアップ

    static var dbPath: String {
        latencyLogURL.deletingLastPathComponent().appendingPathComponent("history.db").path
    }

    public static var latencyLogURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("keynaco", isDirectory: true)
            .appendingPathComponent("latency_log.jsonl")
    }

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
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = FULL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size = -4096;", nil, nil, nil)
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
            pos TEXT DEFAULT NULL,
            lcid INTEGER DEFAULT NULL,
            UNIQUE(input, output)
        );
        CREATE INDEX IF NOT EXISTS idx_input ON history(input);
        CREATE TABLE IF NOT EXISTS user_dict (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            input   TEXT    NOT NULL,
            output  TEXT    NOT NULL,
            UNIQUE(input, output)
        );
        CREATE INDEX IF NOT EXISTS idx_user_dict ON user_dict(input);
        CREATE TABLE IF NOT EXISTS hiragana_preferred (
            word TEXT NOT NULL PRIMARY KEY
        );
        CREATE TABLE IF NOT EXISTS daily_log (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            date         TEXT    NOT NULL,
            committed_text TEXT  NOT NULL,
            created_at   INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_daily_log_date ON daily_log(date);
        CREATE TABLE IF NOT EXISTS diary (
            date         TEXT NOT NULL PRIMARY KEY,
            content      TEXT NOT NULL,
            generated_at INTEGER NOT NULL
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func dispatchWrite(_ block: @escaping () -> Void) {
        if writeAsync { dbQueue.async(execute: block) } else { dbQueue.sync(execute: block) }
    }

    /// テスト用: `PRAGMA user_version` の現在値。
    var schemaUserVersion: Int { currentUserVersion() }

    private func runMigrations() {
        var version = currentUserVersion()
        for migration in SchemaMigration.allCases where migration.rawValue > version {
            applyMigration(migration)
            version = migration.rawValue
            setUserVersion(version)
        }
    }

    private func currentUserVersion() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func setUserVersion(_ version: Int) {
        sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil)
    }

    private func applyMigration(_ migration: SchemaMigration) {
        switch migration {
        case .dropDeprecatedNgramTables: dropDeprecatedNgramTables()
        case .ensureHistoryPOSColumn: ensureHistoryPOSColumn()
        case .dropDeprecatedHistoryColumns: dropDeprecatedHistoryColumns()
        case .ensureDailyLogAppColumn: ensureDailyLogAppColumn()
        case .ensureHistoryLcidColumn: ensureHistoryLcidColumn()
        }
    }

    /// 廃止した bigram / trigram / skip_bigram テーブルを既存 DB から削除する。
    private func dropDeprecatedNgramTables() {
        for table in ["skip_bigram", "trigram", "bigram", "boundary_pref", "noun_bigram", "content_bigram"] {
            sqlite3_exec(db, "DROP TABLE IF EXISTS \(table)", nil, nil, nil)
        }
    }

    /// 既存 DB（pos 列がない）向けマイグレーション。is_noun からの変換も行う。
    func ensureHistoryPOSColumn() {
        sqlite3_exec(db, "ALTER TABLE history ADD COLUMN pos TEXT DEFAULT NULL", nil, nil, nil)
        sqlite3_exec(db, "UPDATE history SET pos = 'noun' WHERE is_noun = 1 AND pos IS NULL", nil, nil, nil)
        sqlite3_exec(db, "UPDATE history SET pos = 'other' WHERE is_noun = 0 AND pos IS NULL", nil, nil, nil)
        // 旧 LLM 列が残っている DB 向け: pos_tag から pos を補完してから DROP する
        sqlite3_exec(db, "ALTER TABLE history ADD COLUMN pos_raw TEXT DEFAULT NULL", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE history ADD COLUMN pos_tag TEXT DEFAULT NULL", nil, nil, nil)
        sqlite3_exec(db, "UPDATE history SET pos_tag = pos_raw WHERE pos_tag IS NULL AND pos_raw IS NOT NULL", nil, nil, nil)
        sqlite3_exec(db, """
            UPDATE history SET pos =
                CASE
                    WHEN pos_tag LIKE 'proper_noun/place%' THEN 'proper_noun/place'
                    WHEN pos_tag LIKE 'proper_noun/person%' THEN 'proper_noun/person'
                    WHEN pos_tag LIKE 'proper_noun/org%'    THEN 'proper_noun/org'
                    ELSE pos
                END
            WHERE pos = 'proper_noun' AND pos_tag IS NOT NULL
            """, nil, nil, nil)
    }

    /// 廃止した LLM 品詞列（pos_tag / pos_retry / lemma / pos_raw）を既存 DB から削除する。
    private func dropDeprecatedHistoryColumns() {
        let deprecated = ["pos_raw", "pos_tag", "pos_retry", "lemma"]
        var changed = false
        for col in deprecated where historyHasColumn(col) {
            sqlite3_exec(db, "ALTER TABLE history DROP COLUMN \(col)", nil, nil, nil)
            changed = true
        }
        if changed {
            for (_, stmt) in stmtCache { sqlite3_finalize(stmt) }
            stmtCache = [:]
        }
    }

    func ensureDailyLogAppColumn() {
        sqlite3_exec(db, "ALTER TABLE daily_log ADD COLUMN app_bundle_id TEXT DEFAULT NULL", nil, nil, nil)
    }

    func ensureHistoryLcidColumn() {
        sqlite3_exec(db, "ALTER TABLE history ADD COLUMN lcid INTEGER DEFAULT NULL", nil, nil, nil)
    }

    private func historyHasColumn(_ name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(history)", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 1), String(cString: ptr) == name { return true }
        }
        return false
    }

    private func seedHiraganaPreferredIfNeeded() {
        guard UserDefaults.standard.object(forKey: Self.hiraganaPreferredSeededKey) == nil else { return }
        seedHiraganaPreferredDefault()
        UserDefaults.standard.set(true, forKey: Self.hiraganaPreferredSeededKey)
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

    public struct HistoryEntry: Sendable {
        public let input: String
        public let output: String
        public let count: Int
        public let pos: String?
        public let lcid: Int?
        public let usedAt: Int64

        public func score(now: Int64 = Int64(Date().timeIntervalSince1970)) -> Double {
            Double(count) / (1.0 + Double(now - usedAt) / DatabaseManager.recencyTauSeconds)
        }
    }

    public struct UserDictEntry: Sendable {
        public let id: Int
        public let input: String
        public let output: String
    }

    /// 確定直後 Backspace（誤変換訂正）で history をペナルティする。
    func penalizeAll(
        input: String,
        output: String,
        fullReading: String?
    ) {
        dispatchWrite {
            let canonical = self.resolveHistoryInputOnQueue(reading: input, output: output)
            self.executeOnQueue("BEGIN")
            self.executeOnQueue("UPDATE history SET count = count - 1 WHERE input = ? AND output = ?") {
                self.bindText($0, 1, canonical); self.bindText($0, 2, output)
            }
            self.executeOnQueue("DELETE FROM history WHERE input = ? AND output = ? AND count <= 0") {
                self.bindText($0, 1, canonical); self.bindText($0, 2, output)
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
            _ = self.cleanupLowScoreHistoryOnQueue(threshold: 0.1)
            sqlite3_exec(self.db, "VACUUM;", nil, nil, nil)
            defaults.set(self.nowEpoch(), forKey: key)
            #if DEBUG
            NSLog("keynaco: DB GC 完了")
            #endif
        }
    }
}
