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

    /// 読みが現在の入力で始まる全エントリを output 単位で SUM 集計して返す。
    /// exact 一致と前方一致（より長い読み）を統合し、異なる読みで確定した回数を正しく合算する。
    func fetchHistoryScoredMerged(reading: String) -> [(output: String, score: Double)] {
        return dbQueue.sync {
            let now = self.nowEpoch()
            return self.queryOutputScorePairsOnQueue("""
            SELECT output, SUM((\(Self.recencyExpr))) AS s FROM history
            WHERE input LIKE ?
            GROUP BY output
            ORDER BY s DESC, MAX(used_at) DESC
            LIMIT 20
            """) {
                self.bindRecency($0, at: 1, now: now)
                self.bindText($0, 3, reading + "%")
            }
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

    /// `input == output` かつ全ひらがなのエントリは学習価値がないため記録しない。
    static func isHiraganaPassthrough(reading: String, output: String) -> Bool {
        guard reading == output else { return false }
        return output.unicodeScalars.allSatisfy { $0.value >= 0x3041 && $0.value <= 0x3096 }
    }

    /// フル読みのみ記録する。前方一致検索は `fetchHistoryScoredMerged` の LIKE クエリが担うため
    /// プレフィックスを個別に記録する必要はない。
    func recordPrefixes(reading: String, output: String) {
        guard !Self.isHiraganaPassthrough(reading: reading, output: output) else { return }
        dispatchWrite {
            let t = self.nowEpoch()
            self.executeOnQueue("""
            INSERT INTO history (input, output, count, used_at)
            VALUES (?, ?, 1, ?)
            ON CONFLICT(input, output) DO UPDATE SET
                count   = count + 1,
                used_at = excluded.used_at;
            """) {
                self.bindText($0, 1, reading); self.bindText($0, 2, output)
                sqlite3_bind_int64($0, 3, t)
            }
        }
    }
}
