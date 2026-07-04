import Foundation
import SQLite3

extension DatabaseManager {
    // MARK: - ユーザー辞書

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

    public func fetchAllUserDict() -> [UserDictEntry] {
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
    public func addUserDict(input: String, output: String) -> Bool {
        dbQueue.sync {
            self.executeOnQueue("INSERT OR IGNORE INTO user_dict (input, output) VALUES (?, ?)") {
                self.bindText($0, 1, input); self.bindText($0, 2, output)
            }
            let inserted = sqlite3_changes(self.db) == 1
            // user_dict は手動登録のため、プロセス kill 後も失わないよう WAL を即時チェックポイント
            if inserted { sqlite3_wal_checkpoint_v2(self.db, nil, SQLITE_CHECKPOINT_FULL, nil, nil) }
            return inserted
        }
    }

    public func deleteUserDict(id: Int) {
        dbQueue.sync {
            self.executeOnQueue("DELETE FROM user_dict WHERE id = ?") {
                sqlite3_bind_int($0, 1, Int32(id))
            }
            sqlite3_wal_checkpoint_v2(self.db, nil, SQLITE_CHECKPOINT_FULL, nil, nil)
        }
    }
}
