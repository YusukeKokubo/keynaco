import Foundation

/// `peekCachedCandidates` / `requestCandidates` の打鍵レイテンシ計測用ローリング統計。
public final class TypingLatencyStats: @unchecked Sendable {
    public enum CachePeekKind: Sendable {
        case exact
        case prefix
        case miss
    }

    public static let minPeeksForFlush = 20
    public static let minFlushInterval: TimeInterval = 300

    public struct Snapshot: Equatable, Sendable {
        public let cacheExact: Int
        public let cachePrefix: Int
        public let cacheMiss: Int
        public let fetchP50Ms: Double?
        public let fetchP95Ms: Double?

        public func asDictionary() -> [String: Any] {
            var dict: [String: Any] = [
                "cache_exact": cacheExact,
                "cache_prefix": cachePrefix,
                "cache_miss": cacheMiss,
            ]
            if let fetchP50Ms { dict["fetch_p50_ms"] = fetchP50Ms }
            if let fetchP95Ms { dict["fetch_p95_ms"] = fetchP95Ms }
            return dict
        }
    }

    private let lock = NSLock()
    private var cacheExact = 0
    private var cachePrefix = 0
    private var cacheMiss = 0
    private var fetchDurationsMs: [Double] = []
    private var currentLabelStorage: String?
    private var lastFlushedAt: Date?
    var nowProvider: () -> Date = { Date() }

    public init() {}

    public var currentLabel: String? {
        get { lock.withLock { currentLabelStorage } }
        set { lock.withLock { currentLabelStorage = newValue } }
    }

    public func recordCachePeek(_ kind: CachePeekKind) {
        lock.withLock {
            switch kind {
            case .exact: cacheExact += 1
            case .prefix: cachePrefix += 1
            case .miss: cacheMiss += 1
            }
        }
    }

    public func recordFetch(ms: Double) {
        lock.withLock {
            fetchDurationsMs.append(ms)
        }
    }

    public func snapshot() -> Snapshot {
        lock.withLock { makeSnapshotLocked() }
    }

    public func reset() {
        lock.withLock {
            cacheExact = 0
            cachePrefix = 0
            cacheMiss = 0
            fetchDurationsMs.removeAll(keepingCapacity: false)
        }
    }

    /// フラッシュ条件を満たすとき JSONL に 1 行追記し、成功時のみカウンタを reset する。
    @discardableResult
    public func appendToLog(fileURL: URL, appVersion: String) -> Bool {
        let prepared: (dict: [String: Any], flushTime: Date)? = lock.withLock {
            let totalPeeks = cacheExact + cachePrefix + cacheMiss
            guard totalPeeks >= Self.minPeeksForFlush else { return nil }

            let now = nowProvider()
            if let lastFlushedAt,
               now.timeIntervalSince(lastFlushedAt) < Self.minFlushInterval {
                return nil
            }

            var dict = makeSnapshotLocked().asDictionary()
            dict["ts"] = Int(now.timeIntervalSince1970)
            dict["version"] = appVersion
            if let label = currentLabelStorage {
                dict["label"] = label
            } else {
                dict["label"] = NSNull()
            }
            dict["total_peeks"] = totalPeeks
            return (dict, now)
        }

        guard let prepared else { return false }
        guard writeJSONLine(prepared.dict, to: fileURL) else { return false }

        lock.withLock {
            cacheExact = 0
            cachePrefix = 0
            cacheMiss = 0
            fetchDurationsMs.removeAll(keepingCapacity: false)
            lastFlushedAt = prepared.flushTime
        }
        return true
    }

    /// JSONL ファイルの末尾 `limit` 行を返す。
    public static func readRecentLines(from fileURL: URL, limit: Int = 20) -> [String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let lines = content
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard lines.count > limit else { return lines }
        return Array(lines.suffix(limit))
    }

    private func makeSnapshotLocked() -> Snapshot {
        let sorted = fetchDurationsMs.sorted()
        let count = sorted.count
        let p50: Double? = count > 0 ? Self.percentile(sorted, p: 50) : nil
        let p95: Double? = count > 0 ? Self.percentile(sorted, p: 95) : nil
        return Snapshot(
            cacheExact: cacheExact,
            cachePrefix: cachePrefix,
            cacheMiss: cacheMiss,
            fetchP50Ms: p50,
            fetchP95Ms: p95
        )
    }

    private func writeJSONLine(_ dict: [String: Any], to fileURL: URL) -> Bool {
        guard JSONSerialization.isValidJSONObject(dict),
              let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              var line = String(data: jsonData, encoding: .utf8) else {
            NSLog("keynaco: latency log JSON serialization failed")
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
            NSLog("keynaco: latency log append failed: \(error)")
            return false
        }
    }

    private static func percentile(_ sorted: [Double], p: Int) -> Double {
        let count = sorted.count
        let idx = min(count - 1, count * p / 100)
        return round(sorted[idx] * 10) / 10
    }
}
