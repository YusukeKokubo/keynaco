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
