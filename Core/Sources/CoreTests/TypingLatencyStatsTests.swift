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
}
