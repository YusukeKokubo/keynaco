import Foundation

/// JSONL ログファイルへの 1 行追記と古い行のトリミング。
enum JSONLWriter {
    struct TrimPolicy: Sendable {
        let userDefaultsKey: String
        let maxLines: Int
        let retentionDays: Int
        let trimIntervalDays: Int = 7
        let logLabel: String

        static let inputLog = TrimPolicy(
            userDefaultsKey: "lastInputLogTrimDate",
            maxLines: 20_000,
            retentionDays: 30,
            logLabel: "input log"
        )

        static let divergenceLog = TrimPolicy(
            userDefaultsKey: "lastDivergenceLogTrimDate",
            maxLines: 20_000,
            retentionDays: 30,
            logLabel: "divergence log"
        )

        static let fetchLog = TrimPolicy(
            userDefaultsKey: "lastFetchLogTrimDate",
            maxLines: 100_000,
            retentionDays: 30,
            logLabel: "fetch log"
        )
    }

    @discardableResult
    static func appendLine(_ dict: [String: Any], to fileURL: URL, logLabel: String) -> Bool {
        guard JSONSerialization.isValidJSONObject(dict),
              let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              var line = String(data: jsonData, encoding: .utf8) else {
            NSLog("keynaco: \(logLabel) JSON serialization failed")
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
            NSLog("keynaco: \(logLabel) append failed: \(error)")
            return false
        }
    }

    static func flushBuffer(_ buffer: [[String: Any]], to fileURL: URL, logLabel: String) {
        for dict in buffer {
            appendLine(dict, to: fileURL, logLabel: logLabel)
        }
    }

    static func trimIfNeeded(fileURL: URL, policy: TrimPolicy) {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if let last = defaults.object(forKey: policy.userDefaultsKey) as? Double,
           now - last < Double(policy.trimIntervalDays) * 86400 { return }

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            defaults.set(now, forKey: policy.userDefaultsKey)
            return
        }

        let allLines = content.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        defaults.set(now, forKey: policy.userDefaultsKey)

        let cutoffMs = (now - Double(policy.retentionDays) * 86400) * 1000
        let lines = allLines.suffix(policy.maxLines).filter { line in
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
        NSLog("keynaco: \(policy.logLabel) trimmed \(allLines.count) → \(lines.count) lines")
        #endif
    }
}

/// buffer + 閾値 flush パターンの共通実装。
final class BufferedJSONLLogger: @unchecked Sendable {
    private let threshold: Int
    private let fileURL: URL
    private let logLabel: String
    private let lock = NSLock()
    private var buffer: [[String: Any]] = []

    init(threshold: Int, fileURL: URL, logLabel: String) {
        self.threshold = threshold
        self.fileURL = fileURL
        self.logLabel = logLabel
    }

    func append(_ dict: [String: Any]) {
        lock.withLock {
            buffer.append(dict)
            if buffer.count >= threshold {
                flushLocked()
            }
        }
    }

    func flushForced() {
        lock.withLock { flushLocked() }
    }

    func withBufferLock<R>(_ body: (inout [[String: Any]]) -> R) -> R {
        lock.withLock { body(&buffer) }
    }

    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        let toWrite = buffer
        buffer.removeAll()
        JSONLWriter.flushBuffer(toWrite, to: fileURL, logLabel: logLabel)
    }
}
