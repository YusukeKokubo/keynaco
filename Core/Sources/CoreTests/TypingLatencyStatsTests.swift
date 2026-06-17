import XCTest
@testable import KeynacoCore

final class TypingLatencyStatsTests: XCTestCase {

    func testRecordCachePeekCounts() {
        let stats = TypingLatencyStats()
        stats.recordCachePeek(.exact)
        stats.recordCachePeek(.exact)
        stats.recordCachePeek(.prefix)
        stats.recordCachePeek(.miss)

        let snap = stats.snapshot()
        XCTAssertEqual(snap.cacheExact, 2)
        XCTAssertEqual(snap.cachePrefix, 1)
        XCTAssertEqual(snap.cacheMiss, 1)
        XCTAssertNil(snap.fetchP50Ms)
        XCTAssertNil(snap.fetchP95Ms)
    }

    func testFetchPercentiles() {
        let stats = TypingLatencyStats()
        for ms in [10.0, 20.0, 30.0, 40.0, 100.0] {
            stats.recordFetch(ms: ms)
        }

        let snap = stats.snapshot()
        XCTAssertEqual(snap.fetchP50Ms, 30.0)
        XCTAssertEqual(snap.fetchP95Ms, 100.0)
    }

    func testResetClearsAll() {
        let stats = TypingLatencyStats()
        stats.recordCachePeek(.miss)
        stats.recordFetch(ms: 42.0)
        stats.reset()

        let snap = stats.snapshot()
        XCTAssertEqual(snap.cacheExact, 0)
        XCTAssertEqual(snap.cachePrefix, 0)
        XCTAssertEqual(snap.cacheMiss, 0)
        XCTAssertNil(snap.fetchP50Ms)
        XCTAssertNil(snap.fetchP95Ms)
    }

    func testSnapshotDictionaryOmitsFetchWhenEmpty() {
        let stats = TypingLatencyStats()
        stats.recordCachePeek(.exact)
        let dict = stats.snapshot().asDictionary()

        XCTAssertEqual(dict["cache_exact"] as? Int, 1)
        XCTAssertNil(dict["fetch_p50_ms"])
        XCTAssertNil(dict["fetch_p95_ms"])
    }

    func testAppendToLogSkipsWhenPeeksInsufficient() throws {
        let stats = TypingLatencyStats()
        let fileURL = temporaryLogURL()

        for _ in 0..<19 { stats.recordCachePeek(.exact) }
        XCTAssertFalse(stats.appendToLog(fileURL: fileURL, appVersion: "0.9.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(stats.snapshot().cacheExact, 19)
    }

    func testAppendToLogWritesAndResetsWhileKeepingLabel() throws {
        let stats = TypingLatencyStats()
        stats.currentLabel = "before-change"
        let fileURL = temporaryLogURL()

        for _ in 0..<20 { stats.recordCachePeek(.miss) }
        stats.recordFetch(ms: 42.0)

        XCTAssertTrue(stats.appendToLog(fileURL: fileURL, appVersion: "0.9.1"))

        let snap = stats.snapshot()
        XCTAssertEqual(snap.cacheExact, 0)
        XCTAssertEqual(snap.cacheMiss, 0)
        XCTAssertEqual(stats.currentLabel, "before-change")

        let lines = TypingLatencyStats.readRecentLines(from: fileURL)
        XCTAssertEqual(lines.count, 1)

        let json = try XCTUnwrap(lines.first?.data(using: .utf8))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(dict["version"] as? String, "0.9.1")
        XCTAssertEqual(dict["label"] as? String, "before-change")
        XCTAssertEqual(dict["total_peeks"] as? Int, 20)
        XCTAssertEqual(dict["cache_miss"] as? Int, 20)
        XCTAssertEqual(dict["fetch_p50_ms"] as? Double, 42.0)
        XCTAssertNotNil(dict["ts"])
    }

    func testAppendToLogEnforcesFiveMinuteThrottle() throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let stats = TypingLatencyStats()
        stats.nowProvider = { now }
        let fileURL = temporaryLogURL()

        for _ in 0..<20 { stats.recordCachePeek(.exact) }
        XCTAssertTrue(stats.appendToLog(fileURL: fileURL, appVersion: "0.9.0"))

        for _ in 0..<20 { stats.recordCachePeek(.prefix) }
        now = now.addingTimeInterval(60)
        XCTAssertFalse(stats.appendToLog(fileURL: fileURL, appVersion: "0.9.0"))
        XCTAssertEqual(stats.snapshot().cachePrefix, 20)

        now = now.addingTimeInterval(4 * 60 + 1)
        XCTAssertTrue(stats.appendToLog(fileURL: fileURL, appVersion: "0.9.0"))
        XCTAssertEqual(TypingLatencyStats.readRecentLines(from: fileURL).count, 2)
    }

    func testAppendToLogFirstFlushHasNoTimeLimit() throws {
        let stats = TypingLatencyStats()
        let fileURL = temporaryLogURL()

        for _ in 0..<20 { stats.recordCachePeek(.miss) }
        XCTAssertTrue(stats.appendToLog(fileURL: fileURL, appVersion: "0.9.0"))
        XCTAssertEqual(TypingLatencyStats.readRecentLines(from: fileURL).count, 1)
    }

    func testReadRecentLinesReturnsLastTwenty() throws {
        let fileURL = temporaryLogURL()
        var lines: [String] = []
        for i in 0..<25 {
            lines.append(#"{"line":\#(i)}"#)
        }
        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        let recent = TypingLatencyStats.readRecentLines(from: fileURL, limit: 20)
        XCTAssertEqual(recent.count, 20)
        XCTAssertEqual(recent.first, #"{"line":5}"#)
        XCTAssertEqual(recent.last, #"{"line":24}"#)
    }

    private func temporaryLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("latency-\(UUID().uuidString).jsonl")
    }
}
