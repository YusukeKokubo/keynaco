import Foundation
import SQLite3

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private var db: OpaquePointer?
    private var stmtCache: [String: OpaquePointer] = [:]
    private let dbQueue = DispatchQueue(label: "keynaco.db", qos: .utility)
    // inMemory=true のテストでは書き込みを同期実行して即座に読み取れるようにする
    private let writeAsync: Bool

    // τ = 30日: 30日経過で count の重みが半減するスケール
    private static let recencyTauSeconds: Double = 30 * 86400
    // 時間減衰スコア式: 各クエリの ORDER BY / SUM で使用する
    private static let recencyExpr = "count * 1.0 / (1.0 + (? - used_at) * 1.0 / ?)"
    var clock: () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    private func nowEpoch() -> Int64 { clock() }

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
    init(inMemory: Bool) {
        writeAsync = false
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return }
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

    private func dispatchWrite(_ block: @escaping () -> Void) {
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
        presetSeedUserDefaults.set(true, forKey: Self.presetSeededUserDefaultsKey)
    }

    // MARK: - SQLite ヘルパー（dbQueue 上でのみ呼び出す）

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    /// recencyExpr の `?` パラメータ（now, tau）を連続した2インデックスにバインドする。
    private func bindRecency(_ stmt: OpaquePointer?, at index: Int32, now: Int64) {
        sqlite3_bind_int64(stmt, index, now)
        sqlite3_bind_double(stmt, index + 1, Self.recencyTauSeconds)
    }

    private func cachedStmt(for sql: String) -> OpaquePointer? {
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

    private func queryStringsOnQueue(
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

    private func queryStringKindPairsOnQueue(
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

    private func queryOutputScorePairsOnQueue(
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

    private func executeOnQueue(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil) {
        guard let stmt = cachedStmt(for: sql) else { return }
        bind?(stmt)
        sqlite3_step(stmt)
    }

    // MARK: - 検索

    /// 読みに完全一致する履歴候補を使用頻度順で返す。
    func fetchHistoryExact(reading: String) -> [String] {
        dbQueue.sync {
            let now = self.nowEpoch()
            return self.queryStringsOnQueue("""
            SELECT output FROM history
            WHERE input = ? COLLATE NOCASE
            ORDER BY (\(Self.recencyExpr)) DESC, used_at DESC
            LIMIT 10
            """) {
                self.bindText($0, 1, reading)
                self.bindRecency($0, at: 2, now: now)
            }
        }
    }

    /// 読みが前方一致する履歴候補を使用頻度順で返す（完全一致は除外）。
    func fetchHistoryPrefix(reading: String) -> [String] {
        dbQueue.sync {
            let now = self.nowEpoch()
            return self.queryStringsOnQueue("""
            SELECT output FROM history
            WHERE input LIKE ? AND input != ?
            GROUP BY output
            ORDER BY (SUM(\(Self.recencyExpr))) DESC, MAX(used_at) DESC
            LIMIT 10
            """) {
                self.bindText($0, 1, reading + "%"); self.bindText($0, 2, reading)
                self.bindRecency($0, at: 3, now: now)
            }
        }
    }

    /// 完全一致を先に、前方一致は重複 output を除いて続ける（`merged(exact,prefix)` と同じ順序）。
    /// スコアは exact の行ごとの recency、prefix は `GROUP BY output` ごとの **MAX(recencyExpr)**（閾値が exact と同尺度）。
    func fetchHistoryScoredMerged(reading: String) -> [(output: String, score: Double)] {
        return dbQueue.sync {
            let now = self.nowEpoch()
            let exactRows = self.queryOutputScorePairsOnQueue("""
            SELECT output, (\(Self.recencyExpr)) AS s FROM history
            WHERE input = ? COLLATE NOCASE
            ORDER BY s DESC, used_at DESC
            LIMIT 10
            """) {
                self.bindRecency($0, at: 1, now: now)
                self.bindText($0, 3, reading)
            }
            let prefixRows = self.queryOutputScorePairsOnQueue("""
            SELECT output, MAX((\(Self.recencyExpr))) AS s FROM history
            WHERE input LIKE ? AND input != ?
            GROUP BY output
            ORDER BY s DESC, MAX(used_at) DESC
            LIMIT 10
            """) {
                self.bindRecency($0, at: 1, now: now)
                self.bindText($0, 3, reading + "%")
                self.bindText($0, 4, reading)
            }
            var seen = Set<String>()
            var merged: [(output: String, score: Double)] = []
            for row in exactRows {
                guard seen.insert(row.0).inserted else { continue }
                merged.append((output: row.0, score: row.1))
            }
            for row in prefixRows {
                guard seen.insert(row.0).inserted else { continue }
                merged.append((output: row.0, score: row.1))
            }
            return merged
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

    struct UserDictEntry {
        let id: Int
        let input: String
        let output: String
    }

    func fetchAllBigram() -> [BigramEntry] {
        dbQueue.sync {
            let sql = "SELECT prev, input, output, count FROM bigram ORDER BY count DESC, used_at DESC LIMIT 1000"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
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
    }

    func deleteBigram(prev: String, input: String, output: String) {
        dispatchWrite {
            self.executeOnQueue("DELETE FROM bigram WHERE prev = ? AND input = ? AND output = ?") {
                self.bindText($0, 1, prev); self.bindText($0, 2, input); self.bindText($0, 3, output)
            }
        }
    }

    func fetchAllHistory() -> [HistoryEntry] {
        dbQueue.sync {
            let sql = "SELECT input, output, count FROM history ORDER BY count DESC, used_at DESC LIMIT 1000"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
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
    }

    func deleteHistoryEntry(input: String, output: String) {
        dispatchWrite {
            self.executeOnQueue("DELETE FROM history WHERE input = ? AND output = ?") {
                self.bindText($0, 1, input); self.bindText($0, 2, output)
            }
        }
    }

    func penalizeHistory(input: String, output: String) {
        dispatchWrite {
            self.executeOnQueue("UPDATE history SET count = count - 1 WHERE input = ? AND output = ?") {
                self.bindText($0, 1, input); self.bindText($0, 2, output)
            }
            self.executeOnQueue("DELETE FROM history WHERE input = ? AND output = ? AND count <= 0") {
                self.bindText($0, 1, input); self.bindText($0, 2, output)
            }
        }
    }

    /// 既存の bi-gram（プリセット以外）を全削除してからインポートデータで置き換える。
    func replaceBigram(_ entries: [BigramEntry]) {
        dbQueue.sync {
            self.executeOnQueue("DELETE FROM bigram WHERE is_preset = 0")
            let sql = """
            INSERT INTO bigram (prev, input, output, count, used_at)
            VALUES (?, ?, ?, ?, ?)
            """
            let t = self.nowEpoch()
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            for entry in entries {
                self.bindText(stmt, 1, entry.prev); self.bindText(stmt, 2, entry.input)
                self.bindText(stmt, 3, entry.output)
                sqlite3_bind_int64(stmt, 4, Int64(entry.count))
                sqlite3_bind_int64(stmt, 5, t)
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
        }
    }

    // MARK: - Bi-gram

    func recordBigram(prev: String, input: String, output: String) {
        dispatchWrite {
            let t = self.nowEpoch()
            self.executeOnQueue("""
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
    }

    func fetchBigram(prev: String, reading: String) -> [String] {
        dbQueue.sync {
            let now = self.nowEpoch()
            return self.queryStringsOnQueue("""
            SELECT output FROM bigram
            WHERE prev = ? AND input LIKE ?
            ORDER BY (\(Self.recencyExpr)) DESC, used_at DESC
            LIMIT 10
            """) {
                self.bindText($0, 1, prev); self.bindText($0, 2, reading + "%")
                self.bindRecency($0, at: 3, now: now)
            }
        }
    }

    /// prev に続く bi-gram 上位候補を返す（input に依らず output を集約）。
    /// 同じ output が複数 input で学習されている場合は count の合計でソートする。
    func fetchBigramTop(prev: String, limit: Int = 20) -> [String] {
        dbQueue.sync {
            let now = self.nowEpoch()
            return self.queryStringsOnQueue("""
            SELECT output FROM bigram
            WHERE prev = ?
            GROUP BY output
            ORDER BY (SUM(\(Self.recencyExpr))) DESC, MAX(used_at) DESC
            LIMIT ?
            """) {
                self.bindText($0, 1, prev)
                self.bindRecency($0, at: 2, now: now)
                sqlite3_bind_int($0, 4, Int32(limit))
            }
        }
    }

    /// prev に続く bi-gram の直近 90 日以内の最大 count を返す。即時表示の閾値判定用。
    func fetchBigramTopCount(prev: String) -> Int {
        dbQueue.sync {
            let cutoff = self.nowEpoch() - 90 * 86400
            let sql = "SELECT MAX(count) FROM bigram WHERE prev = ? AND (used_at > ? OR is_preset = 1)"
            guard let stmt = self.cachedStmt(for: sql) else { return 0 }
            self.bindText(stmt, 1, prev)
            sqlite3_bind_int64(stmt, 2, cutoff)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// list 内の候補を bi-gram 頻度順で返す（未登録分は除外）。
    func fetchBigramInList(prev: String, list: [String]) -> [String] {
        guard !list.isEmpty else { return [] }
        return dbQueue.sync {
            let now = self.nowEpoch()
            let placeholders = list.map { _ in "?" }.joined(separator: ",")
            return self.queryStringsOnQueue("""
            SELECT output FROM bigram
            WHERE prev = ? AND output IN (\(placeholders))
            ORDER BY (\(Self.recencyExpr)) DESC, used_at DESC
            """) {
                self.bindText($0, 1, prev)
                for (i, item) in list.enumerated() { self.bindText($0, Int32(i + 2), item) }
                self.bindRecency($0, at: Int32(list.count + 2), now: now)
            }
        }
    }

    // MARK: - Tri-gram

    func recordTrigram(prev2: String, prev1: String, input: String, output: String) {
        dispatchWrite {
            let t = self.nowEpoch()
            self.executeOnQueue("""
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
    }

    func fetchTrigram(prev2: String, prev1: String, reading: String) -> [String] {
        dbQueue.sync {
            let now = self.nowEpoch()
            return self.queryStringsOnQueue("""
            SELECT output FROM trigram
            WHERE prev2 = ? AND prev1 = ? AND input LIKE ?
            ORDER BY (\(Self.recencyExpr)) DESC, used_at DESC
            LIMIT 10
            """) {
                self.bindText($0, 1, prev2); self.bindText($0, 2, prev1); self.bindText($0, 3, reading + "%")
                self.bindRecency($0, at: 4, now: now)
            }
        }
    }

    func fetchTrigramTop(prev2: String, prev1: String, limit: Int = 20) -> [String] {
        dbQueue.sync {
            let now = self.nowEpoch()
            return self.queryStringsOnQueue("""
            SELECT output FROM trigram
            WHERE prev2 = ? AND prev1 = ?
            GROUP BY output
            ORDER BY (SUM(\(Self.recencyExpr))) DESC, MAX(used_at) DESC
            LIMIT ?
            """) {
                self.bindText($0, 1, prev2); self.bindText($0, 2, prev1)
                self.bindRecency($0, at: 3, now: now)
                sqlite3_bind_int($0, 5, Int32(limit))
            }
        }
    }

    func fetchTrigramInList(prev2: String, prev1: String, list: [String]) -> [String] {
        guard !list.isEmpty else { return [] }
        return dbQueue.sync {
            let now = self.nowEpoch()
            let placeholders = list.map { _ in "?" }.joined(separator: ",")
            return self.queryStringsOnQueue("""
            SELECT output FROM trigram
            WHERE prev2 = ? AND prev1 = ? AND output IN (\(placeholders))
            ORDER BY (\(Self.recencyExpr)) DESC, used_at DESC
            """) {
                self.bindText($0, 1, prev2); self.bindText($0, 2, prev1)
                for (i, item) in list.enumerated() { self.bindText($0, Int32(i + 3), item) }
                self.bindRecency($0, at: Int32(list.count + 3), now: now)
            }
        }
    }

    // MARK: - Skip-Bigram

    func recordSkipBigram(prev: String, input: String, output: String) {
        dispatchWrite {
            let t = self.nowEpoch()
            self.executeOnQueue("""
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
    }

    func fetchSkipBigram(prev: String, reading: String) -> [String] {
        dbQueue.sync {
            let now = self.nowEpoch()
            return self.queryStringsOnQueue("""
            SELECT output FROM skip_bigram
            WHERE prev = ? AND input LIKE ?
            ORDER BY (\(Self.recencyExpr)) DESC, used_at DESC
            LIMIT 10
            """) {
                self.bindText($0, 1, prev); self.bindText($0, 2, reading + "%")
                self.bindRecency($0, at: 3, now: now)
            }
        }
    }

    func fetchSkipBigramTop(prev: String, limit: Int = 20) -> [String] {
        dbQueue.sync {
            let now = self.nowEpoch()
            return self.queryStringsOnQueue("""
            SELECT output FROM skip_bigram
            WHERE prev = ?
            GROUP BY output
            ORDER BY (SUM(\(Self.recencyExpr))) DESC, MAX(used_at) DESC
            LIMIT ?
            """) {
                self.bindText($0, 1, prev)
                self.bindRecency($0, at: 2, now: now)
                sqlite3_bind_int($0, 4, Int32(limit))
            }
        }
    }

    // MARK: - 削除

    /// 履歴から指定の output を持つエントリを削除
    func deleteHistory(output: String) {
        dispatchWrite {
            self.executeOnQueue("DELETE FROM history WHERE output = ?") { self.bindText($0, 1, output) }
        }
    }

    // MARK: - 記録

    /// 変換確定時に履歴へ追記（同じ input/output ペアはカウントアップ）
    func record(input: String, output: String) {
        dispatchWrite {
            let t = self.nowEpoch()
            self.executeOnQueue("""
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
    }

    /// フル読みに加え、先頭 2〜(N-1) 文字の各 prefix でも record する。
    /// 読みが ASCII のみ、または 3 文字未満の場合はフル読みのみ。
    func recordPrefixes(reading: String, output: String) {
        dispatchWrite {
            self.recordPrefixesOnQueue(reading: reading, output: output)
        }
    }

    private func recordPrefixesOnQueue(reading: String, output: String) {
        guard !reading.allSatisfy({ $0.isASCII }) else {
            let t = nowEpoch()
            executeOnQueue("""
            INSERT INTO history (input, output, count, used_at)
            VALUES (?, ?, 1, ?)
            ON CONFLICT(input, output) DO UPDATE SET
                count   = count + 1,
                used_at = excluded.used_at;
            """) {
                self.bindText($0, 1, reading); self.bindText($0, 2, output)
                sqlite3_bind_int64($0, 3, t)
            }
            return
        }
        let chars = Array(reading)
        guard chars.count >= 3 else {
            let t = nowEpoch()
            executeOnQueue("""
            INSERT INTO history (input, output, count, used_at)
            VALUES (?, ?, 1, ?)
            ON CONFLICT(input, output) DO UPDATE SET
                count   = count + 1,
                used_at = excluded.used_at;
            """) {
                self.bindText($0, 1, reading); self.bindText($0, 2, output)
                sqlite3_bind_int64($0, 3, t)
            }
            return
        }
        let now = nowEpoch()
        let prefixes = (2...chars.count).map { String(chars.prefix($0)) }
        let placeholders = prefixes.map { _ in "(?,?,1,?)" }.joined(separator: ",")
        let sql = """
            INSERT INTO history (input, output, count, used_at)
            VALUES \(placeholders)
            ON CONFLICT(input, output) DO UPDATE SET
                count   = count + 1,
                used_at = excluded.used_at;
            """
        executeOnQueue(sql) { stmt in
            for (i, prefix) in prefixes.enumerated() {
                let base = Int32(i * 3 + 1)
                self.bindText(stmt, base, prefix)
                self.bindText(stmt, base + 1, output)
                sqlite3_bind_int64(stmt, base + 2, now)
            }
        }
    }

    /// bigram / trigram / skip-bigram をまとめて1トランザクションでバックグラウンド書き込みする。
    func recordNgrams(
        bigram: (prev: String, input: String, output: String),
        trigram: (prev2: String, prev1: String, input: String, output: String)?,
        skipBigram: (prev: String, input: String, output: String)?
    ) {
        dispatchWrite {
            let t = self.nowEpoch()
            self.executeOnQueue("BEGIN")
            self.executeOnQueue("""
            INSERT INTO bigram (prev, input, output, count, used_at)
            VALUES (?, ?, ?, 1, ?)
            ON CONFLICT(prev, input, output) DO UPDATE SET
                count   = count + 1,
                used_at = excluded.used_at;
            """) {
                self.bindText($0, 1, bigram.prev); self.bindText($0, 2, bigram.input)
                self.bindText($0, 3, bigram.output); sqlite3_bind_int64($0, 4, t)
            }
            if let tri = trigram {
                self.executeOnQueue("""
                INSERT INTO trigram (prev2, prev1, input, output, count, used_at)
                VALUES (?, ?, ?, ?, 1, ?)
                ON CONFLICT(prev2, prev1, input, output) DO UPDATE SET
                    count   = count + 1,
                    used_at = excluded.used_at;
                """) {
                    self.bindText($0, 1, tri.prev2); self.bindText($0, 2, tri.prev1)
                    self.bindText($0, 3, tri.input); self.bindText($0, 4, tri.output)
                    sqlite3_bind_int64($0, 5, t)
                }
            }
            if let skip = skipBigram {
                self.executeOnQueue("""
                INSERT INTO skip_bigram (prev, input, output, count, used_at)
                VALUES (?, ?, ?, 1, ?)
                ON CONFLICT(prev, input, output) DO UPDATE SET
                    count   = count + 1,
                    used_at = excluded.used_at;
                """) {
                    self.bindText($0, 1, skip.prev); self.bindText($0, 2, skip.input)
                    self.bindText($0, 3, skip.output); sqlite3_bind_int64($0, 4, t)
                }
            }
            self.executeOnQueue("COMMIT")
        }
    }

    // MARK: - ユーザー辞書

    func fetchUserDict(reading: String) -> [String] {
        dbQueue.sync {
            self.queryStringsOnQueue("""
            SELECT output FROM user_dict
            WHERE input = ?
            ORDER BY id ASC
            """) {
                self.bindText($0, 1, reading)
            }
        }
    }

    func fetchUserDictPrefix(reading: String) -> [String] {
        dbQueue.sync {
            self.queryStringsOnQueue("""
            SELECT output FROM user_dict
            WHERE ? LIKE (input || '%') AND input != ?
            ORDER BY id ASC
            """) {
                self.bindText($0, 1, reading)
                self.bindText($0, 2, reading)
            }
        }
    }

    /// 完全一致・前方一致のユーザー辞書候補を 1 クエリで返す（buildCandidateList ホットパス用）。
    func fetchUserDictCombined(reading: String) -> (exact: [String], prefix: [String]) {
        let pairs = dbQueue.sync {
            self.queryStringKindPairsOnQueue("""
            SELECT output, kind FROM (
              SELECT output, 0 AS kind, id AS ord FROM user_dict WHERE input = ?
              UNION ALL
              SELECT output, 1 AS kind, id AS ord FROM user_dict
              WHERE ? LIKE (input || '%') AND input != ?
            ) ORDER BY kind ASC, ord ASC
            """) {
                self.bindText($0, 1, reading)
                self.bindText($0, 2, reading)
                self.bindText($0, 3, reading)
            }
        }
        var exact: [String] = []
        var pfx: [String] = []
        for (output, kind) in pairs {
            if kind == 0 { exact.append(output) } else { pfx.append(output) }
        }
        return (exact, pfx)
    }

    func fetchAllUserDict() -> [UserDictEntry] {
        dbQueue.sync {
            let sql = "SELECT id, input, output FROM user_dict ORDER BY id ASC"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var results: [UserDictEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let i = sqlite3_column_text(stmt, 1),
                      let o = sqlite3_column_text(stmt, 2) else { continue }
                results.append(UserDictEntry(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    input: String(cString: i),
                    output: String(cString: o)
                ))
            }
            return results
        }
    }

    @discardableResult
    func addUserDict(input: String, output: String) -> Bool {
        dbQueue.sync {
            self.executeOnQueue("INSERT OR IGNORE INTO user_dict (input, output) VALUES (?, ?)") {
                self.bindText($0, 1, input); self.bindText($0, 2, output)
            }
            return sqlite3_changes(self.db) == 1
        }
    }

    func deleteUserDict(id: Int) {
        dispatchWrite {
            self.executeOnQueue("DELETE FROM user_dict WHERE id = ?") {
                sqlite3_bind_int($0, 1, Int32(id))
            }
        }
    }

    // MARK: - 境界学習

    func saveBoundaryPref(fullReading: String, segments: [String]) {
        guard fullReading.count >= 4 else { return }
        let boundaries = segments.joined(separator: ",")
        dispatchWrite {
            let t = self.nowEpoch()
            self.executeOnQueue("""
            INSERT INTO boundary_pref (full_reading, boundaries, used_at)
            VALUES (?, ?, ?)
            ON CONFLICT(full_reading) DO UPDATE SET
                boundaries = excluded.boundaries,
                used_at    = excluded.used_at;
            """) {
                self.bindText($0, 1, fullReading)
                self.bindText($0, 2, boundaries)
                sqlite3_bind_int64($0, 3, t)
            }
        }
    }

    func fetchBoundaryPref(fullReading: String) -> [String]? {
        let rows = dbQueue.sync {
            self.queryStringsOnQueue(
                """
                SELECT boundaries FROM boundary_pref
                WHERE ? LIKE full_reading || '%'
                ORDER BY length(full_reading) DESC
                LIMIT 1
                """,
                bind: { self.bindText($0, 1, fullReading) }
            )
        }
        return rows.first.map { $0.components(separatedBy: ",") }
    }

    // MARK: - GC

    func performGCIfNeeded() {
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

extension DatabaseManager {
    /// テスト専用: `is_preset` 付き bi-gram を直接挿入する。
    func testInsertBigram(
        prev: String, input: String, output: String, count: Int, usedAt: Int64, isPreset: Bool
    ) {
        dbQueue.sync {
            self.executeOnQueue("""
            INSERT INTO bigram (prev, input, output, count, used_at, is_preset)
            VALUES (?, ?, ?, ?, ?, ?)
            """) { stmt in
                self.bindText(stmt, 1, prev)
                self.bindText(stmt, 2, input)
                self.bindText(stmt, 3, output)
                sqlite3_bind_int64(stmt, 4, Int64(count))
                sqlite3_bind_int64(stmt, 5, usedAt)
                sqlite3_bind_int(stmt, 6, isPreset ? 1 : 0)
            }
        }
    }
}
