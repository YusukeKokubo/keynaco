import Foundation

/// `fetch_log.jsonl` — `AzooKeyConverter.requestCandidates` の実行ごとに 1 行記録する詳細ログ。
///
/// 集計値（`latency_log` の p50/p95）では「どの読みで lock 詰まったか」「どの fetch が wasted だったか」が
/// 見えない。fetch 単位で reading・lock 待ち時間・fetch 所要時間を残し、debounce 改修の効果を
/// reading-level で追えるようにする。
///
/// プライバシー: `reading` フィールドはユーザーの入力（途中状態含む）をそのまま記録する。
/// `~/Library/Application Support/keynaco/` 配下のみ。
public final class FetchLogger: @unchecked Sendable {
    private static let flushThreshold = 50

    private let lock = NSLock()
    private var buffer: [[String: Any]] = []
    private var appVersionStorage = "0.0.0"

    public init() {}

    public var appVersion: String {
        get { lock.withLock { appVersionStorage } }
        set { lock.withLock { appVersionStorage = newValue } }
    }

    public static var logURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("keynaco", isDirectory: true)
            .appendingPathComponent("fetch_log.jsonl")
    }

    public func append(
        reading: String,
        leftContext: String?,
        fetchMs: Double,
        lockWaitMs: Double,
        rich: Bool,
        zenzaiEnabled: Bool
    ) {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        var dict: [String: Any] = [
            "ts": nowMs,
            "ts_iso": LogTimestamp.iso8601(fromUnixMs: nowMs),
            "reading": reading,
            "reading_len": reading.count,
            "fetch_ms": Int(fetchMs.rounded()),
            "lock_wait_ms": Int(lockWaitMs.rounded()),
            "rich": rich,
            "zenzai": zenzaiEnabled,
        ]
        lock.withLock {
            dict["version"] = appVersionStorage
            if let leftContext, !leftContext.isEmpty {
                dict["left_context"] = leftContext
            }
            buffer.append(dict)
            if buffer.count >= Self.flushThreshold {
                flushLocked()
            }
        }
    }

    public func flushForced() {
        lock.withLock { flushLocked() }
    }

    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        let toWrite = buffer
        buffer.removeAll()
        for dict in toWrite {
            Self.writeJSONLine(dict, to: Self.logURL)
        }
    }

    @discardableResult
    private static func writeJSONLine(_ dict: [String: Any], to fileURL: URL) -> Bool {
        guard JSONSerialization.isValidJSONObject(dict),
              let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              var line = String(data: jsonData, encoding: .utf8) else {
            NSLog("keynaco: fetch log JSON serialization failed")
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
            NSLog("keynaco: fetch log append failed: \(error)")
            return false
        }
    }
}
