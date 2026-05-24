import Foundation
import SQLite3

extension DatabaseManager {
    // MARK: - Noun-Bigram

    public func recordNounBigram(prev: String, input: String, output: String) {
        guard !prev.isEmpty else { return }
        dispatchWrite {
            let t = self.nowEpoch()
            self.executeOnQueue("""
            INSERT INTO noun_bigram (prev, input, output, count, used_at)
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

    public func fetchNounBigram(prev: String, reading: String) -> [String] {
        dbQueue.sync {
            let now = self.nowEpoch()
            return self.queryStringsOnQueue("""
            SELECT output FROM noun_bigram
            WHERE prev = ? AND input LIKE ?
            ORDER BY (\(Self.recencyExpr)) DESC, used_at DESC
            LIMIT 10
            """) {
                self.bindText($0, 1, prev); self.bindText($0, 2, reading + "%")
                self.bindRecency($0, at: 3, now: now)
            }
        }
    }

    public struct NounBigramEntry: Sendable {
        public let prev: String
        public let input: String
        public let output: String
        public let count: Int
        public let usedAt: Int64
    }

    public func fetchAllNounBigram() -> [NounBigramEntry] {
        dbQueue.sync {
            let sql = "SELECT prev, input, output, count, used_at FROM noun_bigram ORDER BY count DESC, used_at DESC LIMIT 1000"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var results: [NounBigramEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let p = sqlite3_column_text(stmt, 0),
                      let i = sqlite3_column_text(stmt, 1),
                      let o = sqlite3_column_text(stmt, 2) else { continue }
                results.append(NounBigramEntry(
                    prev: String(cString: p), input: String(cString: i), output: String(cString: o),
                    count: Int(sqlite3_column_int(stmt, 3)), usedAt: sqlite3_column_int64(stmt, 4)
                ))
            }
            return results
        }
    }

    public func deleteNounBigramEntry(prev: String, input: String, output: String) {
        dispatchWrite {
            self.executeOnQueue("DELETE FROM noun_bigram WHERE prev = ? AND input = ? AND output = ?") {
                self.bindText($0, 1, prev); self.bindText($0, 2, input); self.bindText($0, 3, output)
            }
        }
    }

    public func fetchNounBigramTop(prev: String, limit: Int = 20) -> [String] {
        dbQueue.sync {
            let now = self.nowEpoch()
            return self.queryStringsOnQueue("""
            SELECT output FROM noun_bigram
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
}
