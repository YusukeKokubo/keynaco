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
              AND (pos IS NULL OR pos = 'noun' OR pos LIKE 'proper_noun%')
            GROUP BY output
            ORDER BY s DESC, MAX(used_at) DESC
            LIMIT 20
            """) {
                self.bindRecency($0, at: 1, now: now)
                self.bindText($0, 3, reading + "%")
            }
        }
    }

    /// `output` に対応する全履歴行の pos を更新する。
    /// `posRetry=true` の場合は次回分類時に再実行対象となる（低信頼度・フォーマット崩れ時に使用）。
    public func updatePOS(output: String, pos: String, posTag: String? = nil, posRetry: Bool = false) {
        dispatchWrite {
            self.executeOnQueue("UPDATE history SET pos = ?, pos_tag = ?, pos_retry = ? WHERE output = ?") {
                self.bindText($0, 1, pos)
                if let tag = posTag { self.bindText($0, 2, tag) } else { sqlite3_bind_null($0, 2) }
                sqlite3_bind_int($0, 3, posRetry ? 1 : 0)
                self.bindText($0, 4, output)
            }
        }
    }

    /// 直近に確定した固有名詞（subcategory 付き・高信頼度）を重複排除して返す。
    /// Zenzai の topic パラメーター自動推論に使用。
    /// - subcategory（/place・/person・/org）が必須: bare "proper_noun" はパース失敗の可能性が高い
    /// - pos_retry=0: 高/中信頼度のみ（低信頼度は除外）
    /// - 助詞付きエントリ除外: output が助詞で終わるものは誤分類とみなす
    public func recentProperNouns(limit: Int) -> [String] {
        let particles = ["が", "を", "は", "に", "で", "へ", "と", "の", "から", "まで", "より", "など", "て", "も"]
        return dbQueue.sync {
            var results: [String] = []
            let sql = """
            SELECT output FROM history
            WHERE pos IN ('proper_noun/place', 'proper_noun/person', 'proper_noun/org')
              AND pos_retry = 0
            GROUP BY output
            ORDER BY MAX(used_at) DESC, SUM(count) DESC
            LIMIT ?
            """
            guard let stmt = self.cachedStmt(for: sql) else { return results }
            sqlite3_bind_int(stmt, 1, Int32(limit * 3))
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let p = sqlite3_column_text(stmt, 0) else { continue }
                let word = String(cString: p)
                guard !particles.contains(where: { word.hasSuffix($0) }) else { continue }
                results.append(word)
                if results.count >= limit { break }
            }
            return results
        }
    }

    /// 未分類（pos IS NULL）または再試行待ち（pos_retry = 1）の出力語を最大 `limit` 件返す（重複排除）。
    public func fetchUnclassifiedHistory(limit: Int) -> [String] {
        dbQueue.sync {
            var results: [String] = []
            let sql = "SELECT DISTINCT output FROM history WHERE pos IS NULL OR pos_retry = 1 LIMIT ?"
            guard let stmt = self.cachedStmt(for: sql) else { return results }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let p = sqlite3_column_text(stmt, 0) { results.append(String(cString: p)) }
            }
            return results
        }
    }

    public func fetchAllHistory() -> [HistoryEntry] {
        dbQueue.sync {
            let sql = "SELECT input, output, count, pos, pos_tag, pos_retry FROM history ORDER BY count DESC, used_at DESC LIMIT 1000"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var results: [HistoryEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let i = sqlite3_column_text(stmt, 0),
                      let o = sqlite3_column_text(stmt, 1) else { continue }
                let pos = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let posTag = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let posRetry = sqlite3_column_int(stmt, 5) != 0
                results.append(HistoryEntry(
                    input: String(cString: i), output: String(cString: o),
                    count: Int(sqlite3_column_int(stmt, 2)), pos: pos, posTag: posTag, posRetry: posRetry
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
