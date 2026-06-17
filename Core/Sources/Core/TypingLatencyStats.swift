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
        public let peekUpdateP50Ms: Double?
        public let peekUpdateP95Ms: Double?
        public let fetchCompleteP50Ms: Double?
        public let fetchCompleteP95Ms: Double?
        public let debouncePolicyP50Ms: Double?
        public let interKeyP50Ms: Double?
        public let fetchP95ZenzaiOnMs: Double?
        public let fetchP95ZenzaiOffMs: Double?
        public let missRateByReadingLen: [String: Double]

        public func asDictionary() -> [String: Any] {
            var dict: [String: Any] = [
                "cache_exact": cacheExact,
                "cache_prefix": cachePrefix,
                "cache_miss": cacheMiss,
            ]
            if let fetchP50Ms { dict["fetch_p50_ms"] = fetchP50Ms }
            if let fetchP95Ms { dict["fetch_p95_ms"] = fetchP95Ms }
            if let peekUpdateP50Ms { dict["peek_update_p50_ms"] = peekUpdateP50Ms }
            if let peekUpdateP95Ms { dict["peek_update_p95_ms"] = peekUpdateP95Ms }
            if let fetchCompleteP50Ms { dict["fetch_complete_p50_ms"] = fetchCompleteP50Ms }
            if let fetchCompleteP95Ms { dict["fetch_complete_p95_ms"] = fetchCompleteP95Ms }
            if let debouncePolicyP50Ms { dict["debounce_policy_p50_ms"] = debouncePolicyP50Ms }
            if let interKeyP50Ms { dict["inter_key_p50_ms"] = interKeyP50Ms }
            if let fetchP95ZenzaiOnMs { dict["fetch_p95_zenzai_on"] = fetchP95ZenzaiOnMs }
            if let fetchP95ZenzaiOffMs { dict["fetch_p95_zenzai_off"] = fetchP95ZenzaiOffMs }
            if !missRateByReadingLen.isEmpty { dict["miss_rate_by_reading_len"] = missRateByReadingLen }
            return dict
        }
    }

    private let lock = NSLock()
    private var cacheExact = 0
    private var cachePrefix = 0
    private var cacheMiss = 0
    private var fetchDurationsMs: [Double] = []
    private var fetchDurationsZenzaiOnMs: [Double] = []
    private var fetchDurationsZenzaiOffMs: [Double] = []
    private var peekUpdateDurationsMs: [Double] = []
    private var fetchCompleteDurationsMs: [Double] = []
    private var debounceDurationsMs: [Double] = []
    private var interKeyDurationsMs: [Double] = []
    private var peeksByReadingLenBucket: [Int: Int] = [:]
    private var missesByReadingLenBucket: [Int: Int] = [:]
    private var currentLabelStorage: String?
    private var lastFlushedAt: Date?
    var nowProvider: () -> Date = { Date() }

    public init() {}

    public var currentLabel: String? {
        get { lock.withLock { currentLabelStorage } }
        set { lock.withLock { currentLabelStorage = newValue } }
    }

    public func recordCachePeek(_ kind: CachePeekKind, readingLength: Int = 0) {
        lock.withLock {
            switch kind {
            case .exact: cacheExact += 1
            case .prefix: cachePrefix += 1
            case .miss: cacheMiss += 1
            }
            guard readingLength > 0 else { return }
            let bucket = Self.readingLenBucket(readingLength)
            peeksByReadingLenBucket[bucket, default: 0] += 1
            if kind == .miss {
                missesByReadingLenBucket[bucket, default: 0] += 1
            }
        }
    }

    public func recordFetch(ms: Double, zenzaiEnabled: Bool = false) {
        lock.withLock {
            fetchDurationsMs.append(ms)
            if zenzaiEnabled {
                fetchDurationsZenzaiOnMs.append(ms)
            } else {
                fetchDurationsZenzaiOffMs.append(ms)
            }
        }
    }

    public func recordPeekUpdate(ms: Double) {
        lock.withLock {
            peekUpdateDurationsMs.append(ms)
        }
    }

    public func recordFetchComplete(ms: Double) {
        lock.withLock {
            fetchCompleteDurationsMs.append(ms)
        }
    }

    public func recordDebounce(ms: Double) {
        lock.withLock {
            debounceDurationsMs.append(ms)
        }
    }

    public func recordInterKey(ms: Double) {
        lock.withLock {
            interKeyDurationsMs.append(ms)
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
            fetchDurationsZenzaiOnMs.removeAll(keepingCapacity: false)
            fetchDurationsZenzaiOffMs.removeAll(keepingCapacity: false)
            peekUpdateDurationsMs.removeAll(keepingCapacity: false)
            fetchCompleteDurationsMs.removeAll(keepingCapacity: false)
            debounceDurationsMs.removeAll(keepingCapacity: false)
            interKeyDurationsMs.removeAll(keepingCapacity: false)
            peeksByReadingLenBucket.removeAll(keepingCapacity: false)
            missesByReadingLenBucket.removeAll(keepingCapacity: false)
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
            fetchDurationsZenzaiOnMs.removeAll(keepingCapacity: false)
            fetchDurationsZenzaiOffMs.removeAll(keepingCapacity: false)
            peekUpdateDurationsMs.removeAll(keepingCapacity: false)
            fetchCompleteDurationsMs.removeAll(keepingCapacity: false)
            debounceDurationsMs.removeAll(keepingCapacity: false)
            interKeyDurationsMs.removeAll(keepingCapacity: false)
            peeksByReadingLenBucket.removeAll(keepingCapacity: false)
            missesByReadingLenBucket.removeAll(keepingCapacity: false)
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
        let sortedFetch = fetchDurationsMs.sorted()
        let sortedPeekUpdate = peekUpdateDurationsMs.sorted()
        let sortedFetchComplete = fetchCompleteDurationsMs.sorted()
        let sortedDebounce = debounceDurationsMs.sorted()
        let sortedInterKey = interKeyDurationsMs.sorted()
        let sortedFetchZenzaiOn = fetchDurationsZenzaiOnMs.sorted()
        let sortedFetchZenzaiOff = fetchDurationsZenzaiOffMs.sorted()

        return Snapshot(
            cacheExact: cacheExact,
            cachePrefix: cachePrefix,
            cacheMiss: cacheMiss,
            fetchP50Ms: Self.percentile(sortedFetch, p: 50),
            fetchP95Ms: Self.percentile(sortedFetch, p: 95),
            peekUpdateP50Ms: Self.percentile(sortedPeekUpdate, p: 50),
            peekUpdateP95Ms: Self.percentile(sortedPeekUpdate, p: 95),
            fetchCompleteP50Ms: Self.percentile(sortedFetchComplete, p: 50),
            fetchCompleteP95Ms: Self.percentile(sortedFetchComplete, p: 95),
            debouncePolicyP50Ms: Self.percentile(sortedDebounce, p: 50),
            interKeyP50Ms: Self.percentile(sortedInterKey, p: 50),
            fetchP95ZenzaiOnMs: Self.percentile(sortedFetchZenzaiOn, p: 95),
            fetchP95ZenzaiOffMs: Self.percentile(sortedFetchZenzaiOff, p: 95),
            missRateByReadingLen: Self.missRateByReadingLen(
                peeks: peeksByReadingLenBucket,
                misses: missesByReadingLenBucket
            )
        )
    }

    private static func readingLenBucket(_ length: Int) -> Int {
        min(max(length, 1), 5)
    }

    private static func readingLenBucketKey(_ bucket: Int) -> String {
        bucket >= 5 ? "5+" : "\(bucket)"
    }

    private static func missRateByReadingLen(
        peeks: [Int: Int],
        misses: [Int: Int]
    ) -> [String: Double] {
        var rates: [String: Double] = [:]
        for bucket in peeks.keys.sorted() {
            let peekCount = peeks[bucket] ?? 0
            guard peekCount > 0 else { continue }
            let missCount = misses[bucket] ?? 0
            let rate = round(Double(missCount) / Double(peekCount) * 1000) / 1000
            rates[readingLenBucketKey(bucket)] = rate
        }
        return rates
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

    private static func percentile(_ sorted: [Double], p: Int) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let count = sorted.count
        let idx = min(count - 1, count * p / 100)
        return round(sorted[idx] * 10) / 10
    }
}
