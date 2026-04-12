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

    /// ひらがな文字列を辞書最長一致グリーディ法でセグメントに分割する。
    /// 各セグメントの読みと辞書候補を返す。
    func segmentize(_ hiragana: String) -> [(reading: String, candidates: [String])] {
        var result: [(reading: String, candidates: [String])] = []
        var remaining = hiragana
        let maxSegmentLen = 8

        while !remaining.isEmpty {
            var matched = false
            let tryLen = min(remaining.count, maxSegmentLen)
            for length in stride(from: tryLen, through: 2, by: -1) {
                let prefix = String(remaining.prefix(length))
                let candidates = fetchDict(reading: prefix)
                if !candidates.isEmpty {
                    result.append((reading: prefix, candidates: candidates))
                    remaining = String(remaining.dropFirst(length))
                    matched = true
                    break
                }
            }
            if !matched {
                let single = String(remaining.removeFirst())
                result.append((reading: single, candidates: []))
            }
        }
        return result
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
