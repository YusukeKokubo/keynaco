import Foundation
import SQLite3

extension DatabaseManager {
    /// backfill 対象 output の SQL 条件（`pos` 未設定・旧 `other`・`lcid` 欠落）。
    /// 接続詞・感動詞は `lcid` を持たないため除外する。
    fileprivate static let posBackfillOutputFilter = """
    pos IS NULL OR pos = 'other'
    OR (lcid IS NULL AND pos NOT IN ('other/conjunction', 'other/interjection'))
    """

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

    /// 全 history を時間減衰スコアで集計して上位 N 件の (reading, output) を返す。
    /// Settings「ひらがな優先」候補の提案用など。接続詞・感動詞は除外。
    /// 末尾助詞は `recordPrefixes` 側でトリム済みなので追加フィルタは不要。
    public func fetchTopFrequentEntries(limit: Int) -> [(reading: String, output: String)] {
        dbQueue.sync {
            let now = self.nowEpoch()
            let sql = """
            SELECT input, output FROM history
            WHERE (pos IS NULL OR pos NOT IN ('other/conjunction', 'other/interjection'))
              AND input IS NOT NULL AND input != ''
              AND output IS NOT NULL AND output != ''
            GROUP BY input, output
            ORDER BY SUM((\(Self.recencyExpr))) DESC, MAX(used_at) DESC
            LIMIT ?
            """
            guard let stmt = self.cachedStmt(for: sql) else { return [] }
            self.bindRecency(stmt, at: 1, now: now)
            sqlite3_bind_int(stmt, 3, Int32(limit))
            var results: [(reading: String, output: String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let rPtr = sqlite3_column_text(stmt, 0),
                      let oPtr = sqlite3_column_text(stmt, 1) else { continue }
                results.append((String(cString: rPtr), String(cString: oPtr)))
            }
            return results
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

    /// `output` に対応する履歴行の代表 `lcid` を返す。未設定なら nil。
    public func lcidForOutput(_ output: String) -> Int? {
        dbQueue.sync {
            let sql = "SELECT lcid FROM history WHERE output = ? AND lcid IS NOT NULL LIMIT 1"
            guard let stmt = self.cachedStmt(for: sql) else { return nil }
            self.bindText(stmt, 1, output)
            defer { sqlite3_reset(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// `output` に対応する全履歴行の pos / lcid を更新する。`nil` のフィールドは既存値を維持。
    public func updatePOSClassification(output: String, pos: String?, lcid: Int?) {
        guard pos != nil || lcid != nil else { return }
        dispatchWrite {
            self.executeOnQueue("""
            UPDATE history SET
                pos = COALESCE(?, pos),
                lcid = COALESCE(?, lcid)
            WHERE output = ?
            """) {
                if let pos {
                    self.bindText($0, 1, pos)
                } else {
                    sqlite3_bind_null($0, 1)
                }
                if let lcid {
                    sqlite3_bind_int($0, 2, Int32(lcid))
                } else {
                    sqlite3_bind_null($0, 2)
                }
                self.bindText($0, 3, output)
            }
        }
    }

    /// 未分類・`lcid` 欠落の出力語を最大 `limit` 件返す（重複排除）。
    func fetchUnclassifiedHistory(limit: Int) -> [String] {
        dbQueue.sync {
            var results: [String] = []
            let sql = """
            SELECT DISTINCT output FROM history
            WHERE \(Self.posBackfillOutputFilter)
            LIMIT ?
            """
            guard let stmt = self.cachedStmt(for: sql) else { return results }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let p = sqlite3_column_text(stmt, 0) { results.append(String(cString: p)) }
            }
            return results
        }
    }

    /// backfill 対象 output 件数（output 単位）。
    public func countUnclassifiedHistoryOutputs() -> Int {
        dbQueue.sync {
            let sql = """
            SELECT COUNT(*) FROM (
                SELECT DISTINCT output FROM history
                WHERE \(Self.posBackfillOutputFilter)
            )
            """
            guard let stmt = self.cachedStmt(for: sql) else { return 0 }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// backfill 対象エントリを output 単位で返す。reading は同一 output の中で count 最大の input。
    /// `limit` 省略時は全件。
    func fetchUnclassifiedHistoryEntries(limit: Int? = nil) -> [(output: String, reading: String)] {
        dbQueue.sync {
            var results: [(output: String, reading: String)] = []
            let limitClause = limit.map { _ in "LIMIT ?" } ?? ""
            let sql = """
            SELECT output, input FROM (
                SELECT output, input,
                       ROW_NUMBER() OVER (PARTITION BY output ORDER BY count DESC, used_at DESC) AS rn
                FROM history
                WHERE \(Self.posBackfillOutputFilter)
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
            let sql = """
            SELECT input, output, count, pos, lcid, used_at FROM history
            ORDER BY count DESC, used_at DESC LIMIT 1000
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var results: [HistoryEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let i = sqlite3_column_text(stmt, 0),
                      let o = sqlite3_column_text(stmt, 1) else { continue }
                let pos = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let lcid = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int(stmt, 4))
                let usedAt = sqlite3_column_int64(stmt, 5)
                results.append(HistoryEntry(
                    input: String(cString: i), output: String(cString: o),
                    count: Int(sqlite3_column_int(stmt, 2)), pos: pos, lcid: lcid, usedAt: usedAt
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

    /// dbQueue 上で実行する低頻度履歴削除。dispatchWrite ブロック内から呼ぶ。
    func cleanupLowScoreHistoryOnQueue(threshold: Double) -> Int {
        let now = nowEpoch()
        let sql = "DELETE FROM history WHERE count * 1.0 / (1.0 + (? - used_at) * 1.0 / ?) < ?"
        guard let stmt = prepareUncachedStmt(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, now)
        sqlite3_bind_double(stmt, 2, Self.recencyTauSeconds)
        sqlite3_bind_double(stmt, 3, threshold)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    /// 時間減衰スコアが `threshold` 未満のエントリ数を返す（ドライラン）。
    public func countLowScoreHistory(threshold: Double = 0.1) -> Int {
        dbQueue.sync {
            let now = self.nowEpoch()
            let sql = "SELECT COUNT(*) FROM history WHERE count * 1.0 / (1.0 + (? - used_at) * 1.0 / ?) < ?"
            guard let stmt = self.prepareUncachedStmt(sql) else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, now)
            sqlite3_bind_double(stmt, 2, Self.recencyTauSeconds)
            sqlite3_bind_double(stmt, 3, threshold)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// 時間減衰スコアが `threshold` 未満のエントリを削除し、削除件数を返す。
    /// デフォルト閾値 0.1 は count=1・約3ヶ月超相当（τ=30日）。
    @discardableResult
    public func cleanupLowScoreHistory(threshold: Double = 0.1) -> Int {
        dbQueue.sync { self.cleanupLowScoreHistoryOnQueue(threshold: threshold) }
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
        guard output.unicodeScalars.allSatisfy({ KanaUtils.isHiragana($0) }) else { return false }
        // 助詞・助動詞等（HiraganaPreferredBuiltins 登録語）は hiraganaPreferred の固定枠で出るため
        // 履歴記録は不要。それ以外のひらがな語（「さん」等）はユーザーが意図的にひらがな確定した
        // 実績として記録する。
        return HiraganaPreferredBuiltins.words[output] != nil
    }

    /// 格助詞・係助詞・接続助詞のリスト。長い順にソートし長いものを優先マッチさせる。
    /// 格助詞（を・が・に・で・と・へ・より・の・から・まで）、係助詞（は・も）、
    /// 接続助詞（ので・けど）、複合助詞（として）は
    /// いずれも体言や用言に後置されるだけで本体の意味に乗っかっていないため、
    /// 「東京まで」→「東京」のようにトリムしても再利用可能な単位が残る。
    /// 助動詞・終助詞は活用語尾として語幹と一体なので対象外（「でき」等の中途半端な語幹になる）。
    /// 既知の制限:
    /// - `ても`/`でも`（末尾 `も`）等で誤トリムが起きうる
    /// - `ので` は形容動詞連体形と組み合わさると「簡単なので」→「簡単な」のように
    ///   語尾 `な` が残り不完全な語形になる
    /// いずれも reading も同時に壊れるため誤った候補が浮上しにくく、実害が薄いため許容している。
    /// HiraganaPreferredBuiltins.words とは独立した定義。助詞トリムのみが目的。
    static let trailingParticles: [String] = [
        "として", "まで", "から", "ので", "けど",
        "より", "の", "を", "が", "は", "に", "で", "と", "も", "へ",
    ].sorted { $0.count > $1.count }

    /// output 末尾が格助詞・係助詞で終わっている場合、助詞を除いた文字列を返す。
    /// 「東京が」→「東京」、「何時に」→「何時」。対象助詞でなければ nil。
    static func trimTrailingParticle(_ s: String) -> String? {
        for p in trailingParticles where s.hasSuffix(p) {
            let trimmed = String(s.dropLast(p.count))
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// 確定時の読みを1行だけ記録する。同一 output で読みが前方一致関係のときは最長読みに統合し、
    /// 短い読みの行は作らない。前方一致検索は `fetchHistoryScoredMerged` の LIKE が担う。
    /// output 末尾が格助詞・係助詞の場合（例: 「東京が」）、助詞を除いた文節単位（「東京」）で記録する。
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
            self.recordPrefixesOnQueue(reading: r, output: o, now: self.nowEpoch())
        }
    }

    /// `short` が `long` の厳密前方一致か。ラテン文字を含む場合は大文字小文字を無視する。
    static func isReadingPrefix(_ short: String, of long: String) -> Bool {
        guard short != long, short.count < long.count else { return false }
        let hasLatin = short.contains(where: { $0.isASCII && $0.isLetter })
            || long.contains(where: { $0.isASCII && $0.isLetter })
        if hasLatin {
            return long.range(of: short, options: [.caseInsensitive, .anchored]) != nil
        }
        return long.hasPrefix(short)
    }

    /// 同一 output の既存読みのうち、`reading` で確定したときに更新すべき input を返す。
    func resolveHistoryInputOnQueue(reading: String, output: String) -> String {
        let rows = fetchHistoryInputsForOutputOnQueue(output: output)
        if rows.contains(where: { $0.input == reading }) { return reading }
        if let longer = rows
            .filter({ Self.isReadingPrefix(reading, of: $0.input) })
            .max(by: { $0.input.count < $1.input.count }) {
            return longer.input
        }
        return reading
    }

    private struct HistoryInputRow {
        let input: String
        let count: Int
        let usedAt: Int64
    }

    private func fetchHistoryInputsForOutputOnQueue(output: String) -> [HistoryInputRow] {
        let sql = "SELECT input, count, used_at FROM history WHERE output = ?"
        guard let stmt = prepareUncachedStmt(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, output)
        var rows: [HistoryInputRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let inputPtr = sqlite3_column_text(stmt, 0) else { continue }
            rows.append(HistoryInputRow(
                input: String(cString: inputPtr),
                count: Int(sqlite3_column_int(stmt, 1)),
                usedAt: sqlite3_column_int64(stmt, 2)
            ))
        }
        return rows
    }

    private func deleteHistoryEntryOnQueue(input: String, output: String) {
        executeOnQueue("DELETE FROM history WHERE input = ? AND output = ?") {
            self.bindText($0, 1, input); self.bindText($0, 2, output)
        }
    }

    private func upsertHistoryOnQueue(input: String, output: String, addCount: Int, usedAt: Int64) {
        executeOnQueue("""
        INSERT INTO history (input, output, count, used_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(input, output) DO UPDATE SET
            count   = count + excluded.count,
            used_at = excluded.used_at;
        """) {
            self.bindText($0, 1, input); self.bindText($0, 2, output)
            sqlite3_bind_int($0, 3, Int32(addCount))
            sqlite3_bind_int64($0, 4, usedAt)
        }
    }

    /// dbQueue 上で同一 output の前方一致読みを最長1行に統合して記録する。
    func recordPrefixesOnQueue(reading: String, output: String, now: Int64) {
        let rows = fetchHistoryInputsForOutputOnQueue(output: output)
        if let longer = rows
            .filter({ Self.isReadingPrefix(reading, of: $0.input) })
            .max(by: { $0.input.count < $1.input.count }) {
            upsertHistoryOnQueue(input: longer.input, output: output, addCount: 1, usedAt: now)
            return
        }

        var addCount = 1
        var usedAt = now
        for short in rows where Self.isReadingPrefix(short.input, of: reading) {
            addCount += short.count
            usedAt = max(usedAt, short.usedAt)
            deleteHistoryEntryOnQueue(input: short.input, output: output)
        }
        upsertHistoryOnQueue(input: reading, output: output, addCount: addCount, usedAt: usedAt)
    }
}
