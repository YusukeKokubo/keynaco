import XCTest
@testable import keynaco
import KeynacoCore

@MainActor
final class AzooKeyAsyncSchedulerTests: XCTestCase {

    func testScheduleUsesRichCandidates() async {
        let scheduler = AzooKeyAsyncScheduler()
        let stub = RichFlagStub()
        let gen = scheduler.onKeyDown()

        scheduler.schedule(
            generation: gen,
            reading: "かんじ",
            leftSideContext: nil,
            converter: stub
        ) { _ in }

        _ = await scheduler.waitUntilIdle(timeoutNanoseconds: 500_000_000)
        XCTAssertEqual(stub.lastRichCandidates, true)
    }

    func testWarmRichCacheForExplicitCallsConverter() {
        let scheduler = AzooKeyAsyncScheduler()
        let stub = RichFlagStub()
        scheduler.warmRichCacheForExplicit(
            reading: "かんじ",
            leftSideContext: nil,
            converter: stub
        )
        XCTAssertEqual(stub.lastRichCandidates, true)
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testOnKeyDownRecordsInterKeyInterval() {
        let scheduler = AzooKeyAsyncScheduler()
        _ = scheduler.onKeyDown()
        XCTAssertNil(scheduler.lastInterKeyIntervalMs)
        _ = scheduler.onKeyDown()
        XCTAssertNotNil(scheduler.lastInterKeyIntervalMs)
    }

    func testStaleGenerationSkipsDetachedWork() async {
        let scheduler = AzooKeyAsyncScheduler()
        let stub = RichFlagStub()
        let gen = scheduler.onKeyDown()
        scheduler.schedule(
            generation: gen,
            reading: "かんじ",
            leftSideContext: nil,
            converter: stub
        ) { _ in }
        _ = scheduler.onKeyDown()
        try? await Task.sleep(nanoseconds: AzooKeyAsyncScheduler.debounceNanoseconds + 50_000_000)
        XCTAssertNil(stub.lastRichCandidates, "stale generation should skip requestCandidates")
    }

    /// onComplete 内で hasPendingWork が false であること（フッターが fetching のまま残るバグの防止）。
    func testOnCompleteRunsAfterPendingTaskCleared() async {
        let scheduler = AzooKeyAsyncScheduler()
        let stub = RichFlagStub()
        let gen = scheduler.onKeyDown()
        var pendingDuringCallback: Bool?
        scheduler.schedule(
            generation: gen,
            reading: "かんじ",
            leftSideContext: nil,
            converter: stub,
            debounceNanoseconds: 0
        ) { _ in
            pendingDuringCallback = scheduler.hasPendingWork
        }
        _ = await scheduler.waitUntilIdle(timeoutNanoseconds: 500_000_000)
        XCTAssertEqual(pendingDuringCallback, false)
        XCTAssertFalse(scheduler.hasPendingWork)
    }
}

private final class RichFlagStub: AzooKeyConverting, @unchecked Sendable {
    var isZenzaiEnabled: Bool { false }
    let latencyStats = TypingLatencyStats()
    private(set) var lastRichCandidates: Bool?
    private(set) var requestCount = 0

    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        requestCount += 1
        lastRichCandidates = richCandidates
        return ["漢字"]
    }

    func peekCachedCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> AzooKeyCachePeek? {
        nil
    }

    func commit(reading: String, text: String) { _ = (reading, text) }

    func lcidForCommitted(reading: String, output: String) -> Int? { nil }

    func primaryLcidByText(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String: Int] {
        [:]
    }
}
