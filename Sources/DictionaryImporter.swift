import Foundation
import SQLite3

enum DictionaryImporter {

    /// 辞書インポートのバージョン。okuri-ari 対応で 2 に上げる。
    private static let currentVersion = 2

    /// 子音文字 → ひらがな行（五段動詞・形容詞の活用形展開用）
    private static let consonantToKana: [Character: [Character]] = [
        "k": ["か", "き", "く", "け", "こ"],
        "g": ["が", "ぎ", "ぐ", "げ", "ご"],
        "s": ["さ", "し", "す", "せ", "そ"],
        "t": ["た", "ち", "つ", "て", "と"],
        "n": ["な", "に", "ぬ", "ね", "の"],
        "b": ["ば", "び", "ぶ", "べ", "ぼ"],
        "m": ["ま", "み", "む", "め", "も"],
        "r": ["ら", "り", "る", "れ", "ろ"],
        "w": ["わ", "い", "う", "え", "お"],
        "h": ["は", "ひ", "ふ", "へ", "ほ"],
        "z": ["ざ", "じ", "ず", "ぜ", "ぞ"],
        "d": ["だ", "ぢ", "づ", "で", "ど"],
        "p": ["ぱ", "ぴ", "ぷ", "ぺ", "ぽ"],
        "i": ["い"],  // 形容詞 (-い)
        "a": ["あ"],
        "e": ["え"],
        "o": ["お"],
    ]

    /// SKK-JISYO.L をバンドルから読み込み、dictionary テーブルに一括挿入する。
    static func importIfNeeded(db: OpaquePointer?) {
        guard let db = db else { return }

        // meta テーブル作成 & バージョン確認
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)", nil, nil, nil)
        var version = 0
        var vStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'dict_version'", -1, &vStmt, nil) == SQLITE_OK {
            if sqlite3_step(vStmt) == SQLITE_ROW { version = Int(sqlite3_column_int(vStmt, 0)) }
        }
        sqlite3_finalize(vStmt)
        guard version < currentVersion else { return }

        // 旧辞書を削除して再インポート（履歴は保持）
        sqlite3_exec(db, "DELETE FROM dictionary", nil, nil, nil)

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

        var inOkuriAri = false
        var inOkuriNasi = false
        var count = 0

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix(";; okuri-ari entries.") { inOkuriAri = true; continue }
            if line.hasPrefix(";; okuri-nasi entries.") { inOkuriAri = false; inOkuriNasi = true; continue }
            if line.hasPrefix(";;") || line.isEmpty { continue }
            guard inOkuriAri || inOkuriNasi else { continue }

            guard let spaceIdx = line.firstIndex(of: " ") else { continue }
            let reading = String(line[line.startIndex..<spaceIdx])

            let rest = String(line[line.index(after: spaceIdx)...])
            let candidates = rest.split(separator: "/").map { part -> String in
                let s = String(part)
                if let semiIdx = s.firstIndex(of: ";") { return String(s[s.startIndex..<semiIdx]) }
                return s
            }.filter { !$0.isEmpty }

            if inOkuriNasi {
                // okuri-nasi: 読みにASCII文字が含まれるものはスキップ
                if reading.unicodeScalars.contains(where: { $0.value < 0x80 }) { continue }
                for (priority, candidate) in candidates.enumerated() {
                    insert(stmt: stmt, reading: reading, candidate: candidate, priority: Int32(priority))
                    count += 1
                }
            } else {
                // okuri-ari: 末尾が子音文字 → 活用形全て展開して挿入
                // 例: "いk /行/" → (いか,行か),(いき,行き),(いく,行く),(いけ,行け),(いこ,行こ)
                guard let consonant = reading.last, consonant.asciiValue != nil else { continue }
                let stem = String(reading.dropLast())
                // 幹部分がひらがな以外ならスキップ
                guard !stem.isEmpty, stem.unicodeScalars.allSatisfy({ $0.value >= 0x3040 && $0.value <= 0x309F }) else { continue }
                guard let kanaRow = consonantToKana[consonant] else { continue }
                for (priority, candidate) in candidates.enumerated() {
                    for kana in kanaRow {
                        let fullReading = stem + String(kana)
                        let fullCandidate = candidate + String(kana)
                        insert(stmt: stmt, reading: fullReading, candidate: fullCandidate, priority: Int32(priority))
                        count += 1
                    }
                }
            }
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        // バージョンを記録
        sqlite3_exec(db, "INSERT OR REPLACE INTO meta (key, value) VALUES ('dict_version', \(currentVersion))", nil, nil, nil)

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        NSLog("ykey: 辞書インポート完了 — %d エントリ, %.2f秒", count, elapsed)
    }

    private static func insert(stmt: OpaquePointer?, reading: String, candidate: String, priority: Int32) {
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, reading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, candidate, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 3, priority)
        sqlite3_step(stmt)
    }
}
