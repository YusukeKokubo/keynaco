import Foundation
import SQLite3

extension DatabaseManager {
    private enum NgramSinglePrevTable: String {
        case bigram
        case skip_bigram
    }

    /// `prev` 1列・`input` で読み前方一致する N-gram 行から output を返す（bigram / skip_bigram 共通）。
    private func fetchNgramWithReading(table: NgramSinglePrevTable, prev: String, reading: String) -> [String] {
        dbQueue.sync {
            let now = self.nowEpoch()
            let name = table.rawValue
            return self.queryStringsOnQueue("""
            SELECT output FROM \(name)
            WHERE prev = ? AND input LIKE ?
            ORDER BY (\(Self.recencyExpr)) DESC, used_at DESC
            LIMIT 10
            """) {
                self.bindText($0, 1, prev); self.bindText($0, 2, reading + "%")
                self.bindRecency($0, at: 3, now: now)
            }
        }
    }

    /// `prev` 固定で output を GROUP BY し頻度順に返す（`fetchBigramTop` / `fetchSkipBigramTop` 共通）。
    private func fetchNgramTopGrouped(table: NgramSinglePrevTable, prev: String, limit: Int) -> [String] {
        dbQueue.sync {
            let now = self.nowEpoch()
            let name = table.rawValue
            return self.queryStringsOnQueue("""
            SELECT output FROM \(name)
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

    // MARK: - 設定画面用

    public func fetchAllBigram() -> [BigramEntry] {
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

    /// LLM クレンジング等: プリセット行を除いた bi-gram（設定の Bi-gram タブ用 `fetchAllBigram` とは別）。
    public func fetchAllBigramExcludingPresets() -> [BigramEntry] {
        dbQueue.sync {
            let sql = """
            SELECT prev, input, output, count FROM bigram
            WHERE is_preset = 0
            ORDER BY count DESC, used_at DESC LIMIT 1000
            """
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

    public func deleteBigram(prev: String, input: String, output: String) {
        dispatchWrite {
            self.executeOnQueue("DELETE FROM bigram WHERE prev = ? AND input = ? AND output = ?") {
                self.bindText($0, 1, prev); self.bindText($0, 2, input); self.bindText($0, 3, output)
            }
        }
    }

    public func fetchAllTrigram() -> [TrigramEntry] {
        dbQueue.sync {
            let sql = "SELECT prev2, prev1, input, output, count FROM trigram ORDER BY count DESC, used_at DESC LIMIT 1000"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var results: [TrigramEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let p2 = sqlite3_column_text(stmt, 0),
                      let p1 = sqlite3_column_text(stmt, 1),
                      let i  = sqlite3_column_text(stmt, 2),
                      let o  = sqlite3_column_text(stmt, 3) else { continue }
                results.append(TrigramEntry(
                    prev2: String(cString: p2), prev1: String(cString: p1),
                    input: String(cString: i), output: String(cString: o),
                    count: Int(sqlite3_column_int(stmt, 4))
                ))
            }
            return results
        }
    }

    public func deleteTrigram(prev2: String, prev1: String, input: String, output: String) {
        dispatchWrite {
            self.executeOnQueue("DELETE FROM trigram WHERE prev2 = ? AND prev1 = ? AND input = ? AND output = ?") {
                self.bindText($0, 1, prev2); self.bindText($0, 2, prev1)
                self.bindText($0, 3, input); self.bindText($0, 4, output)
            }
        }
    }

    public func deleteSkipBigram(prev: String, input: String, output: String) {
        dispatchWrite {
            self.executeOnQueue("DELETE FROM skip_bigram WHERE prev = ? AND input = ? AND output = ?") {
                self.bindText($0, 1, prev); self.bindText($0, 2, input); self.bindText($0, 3, output)
            }
        }
    }

    /// 既存の bi-gram（プリセット以外）を全削除してからインポートデータで置き換える。
    public func replaceBigram(_ entries: [BigramEntry]) {
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
        fetchNgramWithReading(table: .bigram, prev: prev, reading: reading)
    }

    /// prev に続く bi-gram 上位候補を返す（input に依らず output を集約）。
    /// 同じ output が複数 input で学習されている場合は count の合計でソートする。
    public func fetchBigramTop(prev: String, limit: Int = 20) -> [String] {
        fetchNgramTopGrouped(table: .bigram, prev: prev, limit: limit)
    }

    /// prev に続く bi-gram の直近 90 日以内の最大 count を返す（プリセット行は日付窓外でも含む）。統計・テスト用。
    public func fetchBigramTopCount(prev: String) -> Int {
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
        fetchNgramWithReading(table: .skip_bigram, prev: prev, reading: reading)
    }

    func fetchSkipBigramTop(prev: String, limit: Int = 20) -> [String] {
        fetchNgramTopGrouped(table: .skip_bigram, prev: prev, limit: limit)
    }

    /// bigram / trigram / skip-bigram をまとめて1トランザクションでバックグラウンド書き込みする。
    /// bigram が nil のとき（prev が格助詞）はその記録をスキップし trigram / skip-bigram のみ保存する。
    func recordNgrams(
        bigram: (prev: String, input: String, output: String)?,
        trigram: (prev2: String, prev1: String, input: String, output: String)?,
        skipBigrams: [(prev: String, input: String, output: String)]
    ) {
        dispatchWrite {
            let t = self.nowEpoch()
            self.executeOnQueue("BEGIN")
            if let bigram {
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
            for skip in skipBigrams {
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

    #if DEBUG
    /// デバッグ専用: bi-gram を任意 count で直接挿入する。DebugSocketServer の seed_bigram コマンドから使用。
    public func debugSeedBigram(prev: String, input: String, output: String, count: Int) {
        testInsertBigram(
            prev: prev, input: input, output: output,
            count: count, usedAt: Int64(Date().timeIntervalSince1970), isPreset: false
        )
    }
    #endif

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
