import Foundation
import SQLite3

extension DatabaseManager {
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
}
