import Foundation

/// 入力品質ログ（`input_log.jsonl`）への書き込みとトリミングを担う。
public enum InputQualityLogger {
    public static var inputLogURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("keynaco", isDirectory: true)
            .appendingPathComponent("input_log.jsonl")
    }

    public static func append(record: InputSessionRecord, appVersion: String, to fileURL: URL) {
        var dict = record.asDictionary()
        dict["version"] = appVersion
        writeJSONLine(dict, to: fileURL)
    }

    /// 起動時に古い行を切り詰める。30 日分 or 最新 20000 セッション（先に超えた方）。7 日に 1 回だけ実行。
    public static func trimIfNeeded(fileURL: URL) {
        let key = "lastInputLogTrimDate"
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if let last = defaults.object(forKey: key) as? Double,
           now - last < 7 * 86400 { return }

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            defaults.set(now, forKey: key)
            return
        }

        let allLines = content.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        defaults.set(now, forKey: key)

        let maxLines = 20_000
        let cutoffMs = (now - 30 * 86400) * 1000
        let lines = allLines.suffix(maxLines).filter { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return true
            }
            let ts: Double
            if let v = obj["ts"] as? Int { ts = Double(v) }
            else if let v = obj["ts"] as? Double { ts = v }
            else { return true }
            return ts >= cutoffMs
        }

        guard lines.count < allLines.count else { return }

        let trimmed = lines.joined(separator: "\n") + "\n"
        guard let data = trimmed.data(using: .utf8) else { return }
        try? data.write(to: fileURL)
        #if DEBUG
        NSLog("keynaco: input log trimmed \(allLines.count) → \(lines.count) lines")
        #endif
    }

    @discardableResult
    private static func writeJSONLine(_ dict: [String: Any], to fileURL: URL) -> Bool {
        guard JSONSerialization.isValidJSONObject(dict),
              let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              var line = String(data: jsonData, encoding: .utf8) else {
            NSLog("keynaco: input log JSON serialization failed")
            return false
        }
        line += "\n"
        guard let lineData = line.data(using: .utf8) else { return false }

        let dir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
            } else {
                try lineData.write(to: fileURL)
            }
            return true
        } catch {
            NSLog("keynaco: input log append failed: \(error)")
            return false
        }
    }
}
