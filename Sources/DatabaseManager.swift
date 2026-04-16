import Foundation
import SQLite3

final class DatabaseManager {
    static let shared = DatabaseManager()

    private var db: OpaquePointer?

    private init() {
        openDatabase()
        createTables()
        DictionaryImporter.importIfNeeded(db: db)
    }

    /// テスト用: インメモリ DB で初期化（辞書インポートなし）
    init(inMemory: Bool) {
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return }
        createTables()
    }

    /// テスト用: インメモリ DB で辞書インポートまで実行
    init(inMemoryWithDictionary: Bool) {
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return }
        createTables()
        DictionaryImporter.importIfNeeded(db: db)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - セットアップ

    private func openDatabase() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ykey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("history.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            NSLog("ykey: DB を開けませんでした: \(path)")
            return
        }
        NSLog("ykey: DB パス = \(path)")
    }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS history (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            input   TEXT    NOT NULL,
            output  TEXT    NOT NULL,
            count   INTEGER NOT NULL DEFAULT 1,
            used_at INTEGER NOT NULL,
            UNIQUE(input, output)
        );
        CREATE INDEX IF NOT EXISTS idx_input ON history(input);
        CREATE TABLE IF NOT EXISTS dictionary (
            reading   TEXT    NOT NULL,
            candidate TEXT    NOT NULL,
            priority  INTEGER NOT NULL DEFAULT 0,
            UNIQUE(reading, candidate)
        );
        CREATE INDEX IF NOT EXISTS idx_reading ON dictionary(reading);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - SQLite ヘルパー

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    // MARK: - 検索

    /// 履歴 + 辞書から候補を返す（履歴優先、重複除去）
    /// - Returns: candidates と履歴セクションの件数
    func fetchCandidates(prefix: String) -> (candidates: [String], historyCount: Int) {
        var results: [String] = []
        var seen = Set<String>()

        // 1. 履歴（前方一致、使用頻度順）
        let histSQL = """
        SELECT output FROM history
        WHERE input LIKE ? || '%'
        ORDER BY count DESC, used_at DESC
        LIMIT 20;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, histSQL, -1, &stmt, nil) == SQLITE_OK {
            bindText(stmt, 1, prefix)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 0) {
                    let s = String(cString: ptr)
                    if seen.insert(s).inserted {
                        results.append(s)
                    }
                }
            }
        }
        sqlite3_finalize(stmt)

        let historyCount = results.count

        // 2. 辞書（完全一致、優先度順）
        for candidate in fetchDict(reading: prefix) {
            if seen.insert(candidate).inserted {
                results.append(candidate)
            }
        }

        // 3. 分割変換（各パート2文字以上）
        //    前半: ひらがな or 辞書、後半: ひらがな or 辞書
        //    前半・後半いずれかが辞書にある場合のみ候補生成
        // 分割変換（head >= 2文字, tail >= 2文字 なので prefix は 4文字以上が必要）
        let chars = Array(prefix)
        for i in stride(from: 2, to: chars.count, by: 1) where chars.count - i >= 2 {
            let head = String(chars[..<i])
            let tail = String(chars[i...])
            let headDictCandidates = fetchDict(reading: head)
            let tailDictCandidates = fetchDict(reading: tail)
            // どちらも辞書になければスキップ
            if headDictCandidates.isEmpty && tailDictCandidates.isEmpty { continue }
            let heads = [head] + headDictCandidates.filter { $0 != head }
            let tails = [tail] + tailDictCandidates.filter { $0 != tail }
            // 後半を外側にして、ひらがな後半の候補を先に出す
            for t in tails.prefix(5) {
                for h in heads.prefix(10) {
                    let headIsPureKanji = !h.unicodeScalars.contains {
                        ($0.value >= 0x3040 && $0.value <= 0x309F)
                        || ($0.value >= 0x30A0 && $0.value <= 0x30FF)
                    }
                    let headEndsInHiragana = h.unicodeScalars.last.map {
                        $0.value >= 0x3040 && $0.value <= 0x309F
                    } ?? false
                    let tailContainsHiragana = t.unicodeScalars.contains { $0.value >= 0x3040 && $0.value <= 0x309F }
                    let tailIsPureKanji = !tailContainsHiragana && !t.unicodeScalars.contains {
                        $0.value >= 0x30A0 && $0.value <= 0x30FF
                    }
                    // 純漢字 head + ひらがなを含む tail → 不正（"同言う事"・"堂擦る" 等）
                    if headIsPureKanji && tailContainsHiragana { continue }
                    // 辞書変換済み okurigana head（末尾がひらがな）+ 純漢字 tail → 不正（"良さ会議" 等）
                    // h == head（未変換ひらがな）の場合は除外しない（"いい漢字" は有効）
                    if h != head && headEndsInHiragana && tailIsPureKanji { continue }
                    let compound = h + t
                    if compound == prefix { continue } // 元のひらがなと同じならスキップ
                    if seen.insert(compound).inserted {
                        results.append(compound)
                    }
                }
            }
        }

        return (Array(results.prefix(30)), historyCount)
    }

    /// 指定の読みが過去にセグメントとして確定された合計回数を返す。
    /// segmentize のスコアリングで使用。
    func historyCount(reading: String) -> Int {
        let sql = "SELECT COALESCE(SUM(count), 0) FROM history WHERE input = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        bindText(stmt, 1, reading)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// ひらがな文字列を DP + 履歴スコアリングで最適分割する。
    /// score(seg) = (辞書マッチ長) + min(履歴使用回数, 4)
    /// 辞書・履歴どちらにもない読みは単一文字フォールバックへ。
    func segmentize(_ hiragana: String) -> [(reading: String, candidates: [String])] {
        let chars = Array(hiragana)
        let n = chars.count
        guard n > 0 else { return [] }
        let maxLen = 8

        // DP フェーズとバックトラックで fetchDict / historyCount の重複呼び出しを防ぐキャッシュ
        var dictCache: [String: [String]] = [:]
        var histCache: [String: Int]      = [:]

        // dp[i]: chars[0..<i] を分割したときの最大スコア（-1 = 未到達）
        var dp     = [Int](repeating: -1, count: n + 1)
        var segLen = [Int](repeating: 1,  count: n + 1)
        dp[0] = 0

        for i in 1...n {
            // 単一文字フォールバック（スコア加算なし）
            if dp[i - 1] >= 0 {
                dp[i] = dp[i - 1]
                segLen[i] = 1
            }

            // 辞書 or 履歴にある読み（2文字以上）
            // ※ i=1 のとき 2...1 は ClosedRange がクラッシュするため stride を使う
            for len in stride(from: 2, through: min(i, maxLen), by: 1) {
                let j = i - len
                guard dp[j] >= 0 else { continue }
                let reading = String(chars[j..<i])
                let dictCandidates = dictCache[reading] ?? {
                    let c = fetchDict(reading: reading)
                    dictCache[reading] = c
                    return c
                }()
                let hist = histCache[reading] ?? {
                    let h = historyCount(reading: reading)
                    histCache[reading] = h
                    return h
                }()
                let score = (!dictCandidates.isEmpty ? len : 0) + min(hist, 4)
                guard score > 0 else { continue }
                let candidate = dp[j] + score
                if candidate > dp[i] {
                    dp[i] = candidate
                    segLen[i] = len
                }
            }
        }

        // バックトラック（dictCache を再利用して fetchDict の2重呼び出しを回避）
        var result: [(reading: String, candidates: [String])] = []
        var i = n
        while i > 0 {
            let len = segLen[i]
            let reading = String(chars[(i - len)..<i])
            let candidates = dictCache[reading] ?? fetchDict(reading: reading)
            result.append((reading: reading, candidates: candidates))
            i -= len
        }
        return result.reversed()
    }

    /// テスト用: 辞書エントリを直接追加
    func insertDict(reading: String, candidate: String, priority: Int = 0) {
        let sql = "INSERT OR IGNORE INTO dictionary (reading, candidate, priority) VALUES (?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, reading)
        bindText(stmt, 2, candidate)
        sqlite3_bind_int(stmt, 3, Int32(priority))
        sqlite3_step(stmt)
    }

    /// 辞書から読みの完全一致で候補を取得
    func fetchDict(reading: String) -> [String] {
        let sql = """
        SELECT candidate FROM dictionary
        WHERE reading = ?
        ORDER BY priority ASC
        LIMIT 10;
        """
        var stmt: OpaquePointer?
        var results: [String] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            bindText(stmt, 1, reading)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 0) {
                    results.append(String(cString: ptr))
                }
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    // MARK: - 削除

    /// 履歴から指定の output を持つエントリを削除
    func deleteHistory(output: String) {
        let sql = "DELETE FROM history WHERE output = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, output)
        sqlite3_step(stmt)
    }

    // MARK: - 記録

    /// 変換確定時に履歴へ追記（同じ input/output ペアはカウントアップ）
    func record(input: String, output: String) {
        let sql = """
        INSERT INTO history (input, output, count, used_at)
        VALUES (?, ?, 1, ?)
        ON CONFLICT(input, output) DO UPDATE SET
            count   = count + 1,
            used_at = excluded.used_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let t = Int64(Date().timeIntervalSince1970)
        bindText(stmt, 1, input)
        bindText(stmt, 2, output)
        sqlite3_bind_int64(stmt, 3, t)
        sqlite3_step(stmt)
    }
}
