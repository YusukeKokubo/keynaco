import Foundation
import SQLite3

extension DatabaseManager {
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

    public func fetchAllHistory() -> [HistoryEntry] {
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

    public func deleteHistoryEntry(input: String, output: String) {
        dispatchWrite {
            self.executeOnQueue("DELETE FROM history WHERE input = ? AND output = ?") {
                self.bindText($0, 1, input); self.bindText($0, 2, output)
            }
        }
    }

    /// 履歴から指定の output を持つエントリを削除
    public func deleteHistory(output: String) {
        dispatchWrite {
            self.executeOnQueue("DELETE FROM history WHERE output = ?") { self.bindText($0, 1, output) }
        }
    }

    // MARK: - 記録

    #if DEBUG
    /// デバッグ専用: 履歴エントリを直接挿入する。DebugSocketServer の seed_history コマンドから使用。
    public func debugSeedHistory(input: String, output: String) {
        record(input: input, output: output)
    }
    #endif

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
}
