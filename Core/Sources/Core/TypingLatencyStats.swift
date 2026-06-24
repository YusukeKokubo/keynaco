import Foundation

/// `peekCachedCandidates` / `requestCandidates` の打鍵レイテンシ計測用ローリング統計。
public final class TypingLatencyStats: @unchecked Sendable {
    public enum CachePeekKind: Sendable {
        case exact
        case prefix
        case miss
    }

    /// 候補ウィンドウ表示中の確定が `minConfirmationsForFlush` 回に達したらフラッシュ。
    public static let minConfirmationsForFlush = 5
    public static let minFlushInterval: TimeInterval = 300
    /// 素通り確定が多いセッション向け: peek 回数がこの値以上なら候補確定数に関わらずフラッシュ。
    public static let minPeeksForFlush = 10
    public static let minPeeksFlushInterval: TimeInterval = 180

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
        /// 打鍵間隔の分布（debounce バケット境界 80/160ms の妥当性検証用）。
        public let interKeyP25Ms: Double?
        public let interKeyP75Ms: Double?
        public let interKeyP95Ms: Double?
        public let fetchP95ZenzaiOnMs: Double?
        public let fetchP95ZenzaiOffMs: Double?
        public let missRateByReadingLen: [String: Double]
        public let missCountByReadingLen: [String: Int]
        public let fetchP95ByReadingLen: [String: Double]
        public let candidateConfirmations: Int
        public let firstCandidateRate: Double?
        public let selectionDepthP50: Int?
        public let selectionDepthP95: Int?
        /// AzooKey converter のロック取得待ち時間（ms）。`LockedConverter` で直列化された fetch が
        /// 前の fetch を待った時間。debounce 不足で queue 詰まりするとここが膨らむ。
        public let fetchLockWaitP50Ms: Double?
        public let fetchLockWaitP95Ms: Double?
        /// セッション中に AzooKey converter が実行した fetch 回数（キャッシュヒット除く）。
        public let fetchCount: Int
        /// fetch が走ったが、新キーで世代が進んで結果が破棄された回数。
        /// debounce が batch として機能しとれば低い、毎キー fire しとれば高い。
        public let wastedFetchCount: Int

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
            if let interKeyP25Ms { dict["inter_key_p25_ms"] = interKeyP25Ms }
            if let interKeyP75Ms { dict["inter_key_p75_ms"] = interKeyP75Ms }
            if let interKeyP95Ms { dict["inter_key_p95_ms"] = interKeyP95Ms }
            if let fetchP95ZenzaiOnMs { dict["fetch_p95_zenzai_on"] = fetchP95ZenzaiOnMs }
            if let fetchP95ZenzaiOffMs { dict["fetch_p95_zenzai_off"] = fetchP95ZenzaiOffMs }
            if !missRateByReadingLen.isEmpty { dict["miss_rate_by_reading_len"] = missRateByReadingLen }
            if !missCountByReadingLen.isEmpty { dict["miss_count_by_reading_len"] = missCountByReadingLen }
            if !fetchP95ByReadingLen.isEmpty { dict["fetch_p95_by_reading_len"] = fetchP95ByReadingLen }
            if candidateConfirmations > 0 { dict["candidate_confirmations"] = candidateConfirmations }
            if let firstCandidateRate { dict["first_candidate_rate"] = firstCandidateRate }
            if let selectionDepthP50 { dict["selection_depth_p50"] = selectionDepthP50 }
            if let selectionDepthP95 { dict["selection_depth_p95"] = selectionDepthP95 }
            if let fetchLockWaitP50Ms { dict["fetch_lock_wait_p50_ms"] = fetchLockWaitP50Ms }
            if let fetchLockWaitP95Ms { dict["fetch_lock_wait_p95_ms"] = fetchLockWaitP95Ms }
            if fetchCount > 0 { dict["fetch_count"] = fetchCount }
            if wastedFetchCount > 0 { dict["wasted_fetch_count"] = wastedFetchCount }
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
    private var fetchDurationsMsByReadingLen: [Int: [Double]] = [:]
    private var confirmationDepths: [Int] = []
    private var fetchLockWaitMs: [Double] = []
    private var wastedFetchCountStorage = 0
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

    public func recordFetch(ms: Double, lockWaitMs: Double = 0, zenzaiEnabled: Bool = false, readingLength: Int = 0) {
        lock.withLock {
            fetchDurationsMs.append(ms)
            fetchLockWaitMs.append(lockWaitMs)
            if zenzaiEnabled {
                fetchDurationsZenzaiOnMs.append(ms)
            } else {
                fetchDurationsZenzaiOffMs.append(ms)
            }
            if readingLength > 0 {
                let bucket = Self.readingLenBucket(readingLength)
                fetchDurationsMsByReadingLen[bucket, default: []].append(ms)
            }
        }
    }

    /// fetch を走らせたが、結果が破棄された回数を記録する（debounce 不足の指標）。
    public func recordWastedFetch() {
        lock.withLock { wastedFetchCountStorage += 1 }
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

    /// 候補ウィンドウ表示中の確定を記録する。`selectionDepth` は選択行（候補非表示なら nil）。
    public func recordConfirmation(selectionDepth: Int?) {
        guard let depth = selectionDepth else { return }
        lock.withLock { confirmationDepths.append(depth) }
    }

    public func snapshot() -> Snapshot {
        lock.withLock { makeSnapshotLocked() }
    }

    public func reset() {
        lock.withLock { resetLocked() }
    }

    /// 通常フラッシュ: (1) 候補確定 5 回 + 5 分、(2) peek 10 回 + 3 分のいずれか。
    @discardableResult
    public func appendToLog(fileURL: URL, appVersion: String) -> Bool {
        let strategies: [(minConfirmations: Int, minPeeks: Int, minInterval: TimeInterval)] = [
            (Self.minConfirmationsForFlush, 0, Self.minFlushInterval),
            (0, Self.minPeeksForFlush, Self.minPeeksFlushInterval),
        ]
        for strategy in strategies {
            let prepared = buildFlushPayloadLocked(
                appVersion: appVersion,
                minConfirmations: strategy.minConfirmations,
                minPeeks: strategy.minPeeks,
                minInterval: strategy.minInterval
            )
            if writePrepared(prepared, to: fileURL) { return true }
        }
        return false
    }

    /// 強制フラッシュ: 件数条件なし・インターバルなし。アプリ非アクティブ時に短セッションのデータを保全する。
    @discardableResult
    public func appendToLogForced(fileURL: URL, appVersion: String) -> Bool {
        let prepared = buildFlushPayloadLocked(
            appVersion: appVersion,
            minConfirmations: 0,
            minPeeks: 0,
            minInterval: 0
        )
        return writePrepared(prepared, to: fileURL)
    }

    /// 起動時に古い行を切り詰める。`keepLines` 件以内なら何もしない。7 日に 1 回だけ実行する。
    public static func trimLogIfNeeded(fileURL: URL, keepLines: Int = 2000) {
        let key = "lastLatencyLogTrimDate"
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if let last = defaults.object(forKey: key) as? Double,
           now - last < 7 * 86400 { return }

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            defaults.set(now, forKey: key)
            return
        }

        let lines = content.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        defaults.set(now, forKey: key)
        guard lines.count > keepLines else { return }

        let trimmed = lines.suffix(keepLines).joined(separator: "\n") + "\n"
        guard let data = trimmed.data(using: .utf8) else { return }
        try? data.write(to: fileURL)
        #if DEBUG
        NSLog("keynaco: latency log trimmed \(lines.count) → \(keepLines) lines")
        #endif
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

    private func buildFlushPayloadLocked(
        appVersion: String,
        minConfirmations: Int,
        minPeeks: Int,
        minInterval: TimeInterval
    ) -> (dict: [String: Any], flushTime: Date)? {
        lock.withLock {
            let confirmations = confirmationDepths.count
            let totalPeeks = cacheExact + cachePrefix + cacheMiss
            let hasData = confirmations > 0 || totalPeeks > 0
            if minConfirmations > 0 {
                guard confirmations >= minConfirmations else { return nil }
            } else if minPeeks > 0 {
                guard totalPeeks >= minPeeks else { return nil }
            } else {
                guard hasData else { return nil }
            }

            let now = nowProvider()
            if minInterval > 0, let lastFlushedAt,
               now.timeIntervalSince(lastFlushedAt) < minInterval {
                return nil
            }

            var dict = makeSnapshotLocked().asDictionary()
            dict["ts"] = Int(now.timeIntervalSince1970)
            dict["ts_iso"] = LogTimestamp.iso8601String(from: now)
            dict["version"] = appVersion
            if let label = currentLabelStorage {
                dict["label"] = label
            } else {
                dict["label"] = NSNull()
            }
            dict["total_peeks"] = totalPeeks
            return (dict, now)
        }
    }

    private func writePrepared(_ prepared: (dict: [String: Any], flushTime: Date)?, to fileURL: URL) -> Bool {
        guard let prepared else { return false }
        guard writeJSONLine(prepared.dict, to: fileURL) else { return false }
        lock.withLock {
            resetLocked()
            lastFlushedAt = prepared.flushTime
        }
        return true
    }

    private func makeSnapshotLocked() -> Snapshot {
        let sortedFetch = fetchDurationsMs.sorted()
        let sortedPeekUpdate = peekUpdateDurationsMs.sorted()
        let sortedFetchComplete = fetchCompleteDurationsMs.sorted()
        let sortedDebounce = debounceDurationsMs.sorted()
        let sortedInterKey = interKeyDurationsMs.sorted()
        let sortedFetchZenzaiOn = fetchDurationsZenzaiOnMs.sorted()
        let sortedFetchZenzaiOff = fetchDurationsZenzaiOffMs.sorted()
        let sortedDepths = confirmationDepths.sorted()

        let firstCandidateRate: Double? = sortedDepths.isEmpty ? nil :
            round(Double(sortedDepths.filter { $0 == 0 }.count) / Double(sortedDepths.count) * 1000) / 1000

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
            interKeyP25Ms: Self.percentile(sortedInterKey, p: 25),
            interKeyP75Ms: Self.percentile(sortedInterKey, p: 75),
            interKeyP95Ms: Self.percentile(sortedInterKey, p: 95),
            fetchP95ZenzaiOnMs: Self.percentile(sortedFetchZenzaiOn, p: 95),
            fetchP95ZenzaiOffMs: Self.percentile(sortedFetchZenzaiOff, p: 95),
            missRateByReadingLen: Self.missRateByReadingLen(
                peeks: peeksByReadingLenBucket,
                misses: missesByReadingLenBucket
            ),
            missCountByReadingLen: Self.missCountByReadingLen(misses: missesByReadingLenBucket),
            fetchP95ByReadingLen: Self.fetchP95ByReadingLen(durationsByBucket: fetchDurationsMsByReadingLen),
            candidateConfirmations: sortedDepths.count,
            firstCandidateRate: firstCandidateRate,
            selectionDepthP50: Self.percentileInt(sortedDepths, p: 50),
            selectionDepthP95: Self.percentileInt(sortedDepths, p: 95),
            fetchLockWaitP50Ms: Self.percentile(fetchLockWaitMs.sorted(), p: 50),
            fetchLockWaitP95Ms: Self.percentile(fetchLockWaitMs.sorted(), p: 95),
            fetchCount: fetchDurationsMs.count,
            wastedFetchCount: wastedFetchCountStorage
        )
    }

    private func resetLocked() {
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
        fetchDurationsMsByReadingLen.removeAll(keepingCapacity: false)
        confirmationDepths.removeAll(keepingCapacity: false)
        fetchLockWaitMs.removeAll(keepingCapacity: false)
        wastedFetchCountStorage = 0
    }

    private static func readingLenBucket(_ length: Int) -> Int {
        min(max(length, 1), 5)
    }

    private static func readingLenBucketKey(_ bucket: Int) -> String {
        bucket >= 5 ? "5+" : "\(bucket)"
    }

    private static func missCountByReadingLen(misses: [Int: Int]) -> [String: Int] {
        misses.reduce(into: [:]) { $0[readingLenBucketKey($1.key)] = $1.value }
    }

    private static func fetchP95ByReadingLen(durationsByBucket: [Int: [Double]]) -> [String: Double] {
        durationsByBucket.reduce(into: [:]) { result, pair in
            let sorted = pair.value.sorted()
            if let p95 = percentile(sorted, p: 95) {
                result[readingLenBucketKey(pair.key)] = p95
            }
        }
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

    private static func percentileInt(_ sorted: [Int], p: Int) -> Int? {
        guard !sorted.isEmpty else { return nil }
        let idx = min(sorted.count - 1, sorted.count * p / 100)
        return sorted[idx]
    }
}
