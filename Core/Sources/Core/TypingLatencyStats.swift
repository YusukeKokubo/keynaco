import Foundation

/// `peekCachedCandidates` / `requestCandidates` の打鍵レイテンシ計測用ローリング統計。
public final class TypingLatencyStats: @unchecked Sendable {
    public enum CachePeekKind: Sendable {
        case exact
        case prefix
        case miss
    }

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

    public init() {}

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
        lock.withLock {
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
    }

    public func reset() {
        lock.withLock {
            cacheExact = 0
            cachePrefix = 0
            cacheMiss = 0
            fetchDurationsMs.removeAll(keepingCapacity: false)
        }
    }

    private static func percentile(_ sorted: [Double], p: Int) -> Double {
        let count = sorted.count
        let idx = min(count - 1, count * p / 100)
        return round(sorted[idx] * 10) / 10
    }
}
