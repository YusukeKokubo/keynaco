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
    ///
    /// **設計不変条件**: `LIKE 'reading%'` で exact + 前方一致を一括取得し `GROUP BY output` の
    /// `SUM` で集計する。exact / prefix を別クエリに分割し `MAX` で合計する設計に書き換えると、
    /// 異なる読み長で確定した回数が合算されなくなり履歴ランキングが壊れる。
    func fetchHistoryScoredMerged(reading: String) -> [(output: String, score: Double)] {
        return dbQueue.sync {
            let now = self.nowEpoch()
            return self.queryOutputScorePairsOnQueue("""
            SELECT output, SUM((\(Self.recencyExpr))) AS s FROM history
            WHERE input LIKE ?
              AND (pos IS NULL OR pos NOT IN ('other/conjunction', 'other/interjection'))
            GROUP BY output
            ORDER BY s DESC, MAX(used_at) DESC
            LIMIT 20
            """) {
                self.bindRecency($0, at: 1, now: now)
                self.bindText($0, 3, reading + "%")
            }
        }
    }

    /// `output` がすでに分類済みなら pos を返す。未分類または未登録なら nil。
    public func posForOutput(_ output: String) -> String? {
        dbQueue.sync {
            let sql = "SELECT pos FROM history WHERE output = ? AND pos IS NOT NULL LIMIT 1"
            guard let stmt = self.cachedStmt(for: sql) else { return nil }
            self.bindText(stmt, 1, output)
            defer { sqlite3_reset(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
        }
    }

    /// `output` に対応する全履歴行の pos を更新する。
    public func updatePOS(output: String, pos: String) {
        dispatchWrite {
            self.executeOnQueue("UPDATE history SET pos = ? WHERE output = ?") {
                self.bindText($0, 1, pos)
                self.bindText($0, 2, output)
            }
        }
    }

    /// 未分類（pos IS NULL）の出力語を最大 `limit` 件返す（重複排除）。
    public func fetchUnclassifiedHistory(limit: Int) -> [String] {
        dbQueue.sync {
            var results: [String] = []
            let sql = "SELECT DISTINCT output FROM history WHERE pos IS NULL LIMIT ?"
            guard let stmt = self.cachedStmt(for: sql) else { return results }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let p = sqlite3_column_text(stmt, 0) { results.append(String(cString: p)) }
            }
            return results
        }
    }

    /// 未分類 output 件数（`pos IS NULL`、output 単位）。
    public func countUnclassifiedHistoryOutputs() -> Int {
        dbQueue.sync {
            let sql = """
            SELECT COUNT(*) FROM (
                SELECT DISTINCT output FROM history WHERE pos IS NULL
            )
            """
            guard let stmt = self.cachedStmt(for: sql) else { return 0 }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// 未分類エントリを output 単位で返す。reading は同一 output の中で count 最大の input。
    /// `limit` 省略時は全件。
    public func fetchUnclassifiedHistoryEntries(limit: Int? = nil) -> [(output: String, reading: String)] {
        dbQueue.sync {
            var results: [(output: String, reading: String)] = []
            let limitClause = limit.map { _ in "LIMIT ?" } ?? ""
            let sql = """
            SELECT output, input FROM (
                SELECT output, input,
                       ROW_NUMBER() OVER (PARTITION BY output ORDER BY count DESC, used_at DESC) AS rn
                FROM history
                WHERE pos IS NULL
            )
            WHERE rn = 1
            \(limitClause)
            """
            guard let stmt = self.prepareUncachedStmt(sql) else { return results }
            defer { sqlite3_finalize(stmt) }
            if let limit { sqlite3_bind_int(stmt, 1, Int32(limit)) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let o = sqlite3_column_text(stmt, 0),
                      let i = sqlite3_column_text(stmt, 1) else { continue }
                results.append((output: String(cString: o), reading: String(cString: i)))
            }
            return results
        }
    }

    /// LIMIT 句の有無で SQL が変わるため stmt キャッシュを使わない。
    func prepareUncachedStmt(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    public func fetchAllHistory() -> [HistoryEntry] {
        dbQueue.sync {
            let sql = "SELECT input, output, count, pos, used_at FROM history ORDER BY count DESC, used_at DESC LIMIT 1000"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var results: [HistoryEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let i = sqlite3_column_text(stmt, 0),
                      let o = sqlite3_column_text(stmt, 1) else { continue }
                let pos = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let usedAt = sqlite3_column_int64(stmt, 4)
                results.append(HistoryEntry(
                    input: String(cString: i), output: String(cString: o),
                    count: Int(sqlite3_column_int(stmt, 2)), pos: pos, usedAt: usedAt
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

    /// 格助詞のリスト。長い順にソートし「より」を「よ」より先にマッチさせる。
    /// 格助詞は体言（名詞）に後置されるだけで本体の意味に乗っかっていないため、
    /// 「東京が」→「東京」のようにトリムしても再利用可能な単位が残る。
    /// 助動詞・終助詞は活用語尾として語幹と一体なので対象外（「でき」等の中途半端な語幹になる）。
    /// HiraganaPreferredBuiltins.words とは独立した定義。格助詞トリムのみが目的。
    static let trailingParticles: [String] = ["より", "の", "を", "が", "は", "に", "で", "と", "も", "へ"]
        .sorted { $0.count > $1.count }

    /// output 末尾が格助詞で終わっている場合、助詞を除いた文字列を返す。
    /// 「東京が」→「東京」、「何時に」→「何時」。格助詞でなければ nil。
    static func trimTrailingParticle(_ s: String) -> String? {
        for p in trailingParticles where s.hasSuffix(p) {
            let trimmed = String(s.dropLast(p.count))
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// フル読みのみ記録する。前方一致検索は `fetchHistoryScoredMerged` の LIKE クエリが担うため
    /// プレフィックスを個別に記録する必要はない。
    /// output 末尾が格助詞の場合（例: 「東京が」）、助詞を除いた文節単位（「東京」）で記録する。
    /// reading も同じ助詞文字列分だけ末尾を除去する（全ひらがな reading の場合は維持）。
    func recordPrefixes(reading: String, output: String) {
        let (r, o): (String, String)
        if let trimmedOutput = Self.trimTrailingParticle(output) {
            let particle = String(output.dropFirst(trimmedOutput.count))
            let trimmedReading = reading.hasSuffix(particle) ? String(reading.dropLast(particle.count)) : ""
            r = trimmedReading.isEmpty ? reading : trimmedReading
            o = trimmedOutput
        } else {
            r = reading; o = output
        }
        guard !Self.isHiraganaPassthrough(reading: r, output: o) else { return }
        dispatchWrite {
            let t = self.nowEpoch()
            self.executeOnQueue("""
            INSERT INTO history (input, output, count, used_at)
            VALUES (?, ?, 1, ?)
            ON CONFLICT(input, output) DO UPDATE SET
                count   = count + 1,
                used_at = excluded.used_at;
            """) {
                self.bindText($0, 1, r); self.bindText($0, 2, o)
                sqlite3_bind_int64($0, 3, t)
            }
        }
    }
}
