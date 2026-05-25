import Foundation
import SQLite3

extension DatabaseManager {
    static let defaultHiraganaPreferredWords: [String] = [
        "ちょっと", "とりあえず",
    ]

    public func fetchHiraganaPreferredSet() -> Set<String> {
        dbQueue.sync {
            Set(self.queryStringsOnQueue("SELECT word FROM hiragana_preferred"))
        }
    }

    public func fetchAllHiraganaPreferred() -> [String] {
        dbQueue.sync {
            self.queryStringsOnQueue("SELECT word FROM hiragana_preferred ORDER BY word ASC")
        }
    }

    @discardableResult
    public func addHiraganaPreferred(word: String) -> Bool {
        dbQueue.sync {
            self.executeOnQueue("INSERT OR IGNORE INTO hiragana_preferred (word) VALUES (?)") {
                self.bindText($0, 1, word)
            }
            let inserted = sqlite3_changes(self.db) == 1
            if inserted { sqlite3_wal_checkpoint_v2(self.db, nil, SQLITE_CHECKPOINT_FULL, nil, nil) }
            return inserted
        }
    }

    public func deleteHiraganaPreferred(word: String) {
        dbQueue.sync {
            self.executeOnQueue("DELETE FROM hiragana_preferred WHERE word = ?") {
                self.bindText($0, 1, word)
            }
            sqlite3_wal_checkpoint_v2(self.db, nil, SQLITE_CHECKPOINT_FULL, nil, nil)
        }
    }

    /// init から直接呼ぶ用（dbQueue を使わず executeOnQueue を直接呼ぶ）。
    func seedHiraganaPreferredDefault() {
        executeOnQueue("BEGIN")
        for word in Self.defaultHiraganaPreferredWords {
            executeOnQueue("INSERT OR IGNORE INTO hiragana_preferred (word) VALUES (?)") {
                self.bindText($0, 1, word)
            }
        }
        executeOnQueue("COMMIT")
    }

    /// テスト用: dbQueue.sync でシードする。
    func seedHiraganaPreferredWords() {
        dbQueue.sync {
            self.executeOnQueue("BEGIN")
            for word in Self.defaultHiraganaPreferredWords {
                self.executeOnQueue("INSERT OR IGNORE INTO hiragana_preferred (word) VALUES (?)") {
                    self.bindText($0, 1, word)
                }
            }
            self.executeOnQueue("COMMIT")
        }
    }
}
