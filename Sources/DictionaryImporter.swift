import Foundation
import SQLite3

enum DictionaryImporter {

    /// SKK-JISYO.L をバンドルから読み込み、dictionary テーブルに一括挿入する。
    static func importIfNeeded(db: OpaquePointer?) {
        guard let db = db else { return }

        // 既にインポート済みならスキップ
        var countStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM dictionary", -1, &countStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(countStmt) }
        guard sqlite3_step(countStmt) == SQLITE_ROW, sqlite3_column_int(countStmt, 0) == 0 else { return }

        guard let url = Bundle.main.url(forResource: "SKK-JISYO-L", withExtension: "utf8"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("ykey: SKK-JISYO.L が見つからないか読み込めません")
            return
        }

        NSLog("ykey: 辞書インポート開始")
        let start = CFAbsoluteTimeGetCurrent()

        sqlite3_exec(db, "BEGIN", nil, nil, nil)

        let sql = "INSERT OR IGNORE INTO dictionary (reading, candidate, priority) VALUES (?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }
        defer { sqlite3_finalize(stmt) }

        var inOkuriNasi = false
        var count = 0

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix(";; okuri-nasi entries.") {
                inOkuriNasi = true
                continue
            }
            if line.hasPrefix(";;") || line.isEmpty { continue }
            if !inOkuriNasi { continue }

            // "あい /愛/哀/相/" → reading="あい", candidates=["愛","哀","相"]
            guard let spaceIdx = line.firstIndex(of: " ") else { continue }
            let reading = String(line[line.startIndex..<spaceIdx])

            // 読みにASCII文字が含まれるものはスキップ（送り仮名付きエントリ）
            if reading.unicodeScalars.contains(where: { $0.value < 0x80 }) { continue }

            let rest = String(line[line.index(after: spaceIdx)...])
            let candidates = rest.split(separator: "/").map { part -> String in
                // "愛;名詞" → "愛" (アノテーション除去)
                let s = String(part)
                if let semiIdx = s.firstIndex(of: ";") {
                    return String(s[s.startIndex..<semiIdx])
                }
                return s
            }.filter { !$0.isEmpty }

            for (priority, candidate) in candidates.enumerated() {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, reading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 2, candidate, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_int(stmt, 3, Int32(priority))
                sqlite3_step(stmt)
                count += 1
            }
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        NSLog("ykey: 辞書インポート完了 — %d エントリ, %.2f秒", count, elapsed)
    }
}
