import XCTest
@testable import keynaco
import KeynacoCore

@MainActor
final class AzooKeyAsyncSchedulerTests: XCTestCase {

    func testScheduleUsesRichCandidates() async {
        let scheduler = AzooKeyAsyncScheduler()
        let stub = RichFlagStub()
        let gen = scheduler.onKeyDown(converter: stub)

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
        let stub = RichFlagStub()
        _ = scheduler.onKeyDown(converter: stub)
        XCTAssertNil(scheduler.lastInterKeyIntervalMs)
        _ = scheduler.onKeyDown(converter: stub)
        XCTAssertNotNil(scheduler.lastInterKeyIntervalMs)
    }

    func testStaleGenerationSkipsDetachedWork() async {
        let scheduler = AzooKeyAsyncScheduler()
        let stub = RichFlagStub()
        let gen = scheduler.onKeyDown(converter: stub)
        scheduler.schedule(
            generation: gen,
            reading: "かんじ",
            leftSideContext: nil,
            converter: stub
        ) { _ in }
        _ = scheduler.onKeyDown(converter: stub)
        try? await Task.sleep(nanoseconds: AzooKeyAsyncScheduler.debounceNanoseconds + 50_000_000)
        XCTAssertNil(stub.lastRichCandidates, "stale generation should skip requestCandidates")
    }

    /// onComplete 内で hasPendingWork が false であること（フッターが fetching のまま残るバグの防止）。
    func testOnCompleteRunsAfterPendingTaskCleared() async {
        let scheduler = AzooKeyAsyncScheduler()
        let stub = RichFlagStub()
        let gen = scheduler.onKeyDown(converter: stub)
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
    var fetchLogger: FetchLogger { FetchLogger.sharedNoOp }
    private(set) var lastRichCandidates: Bool?
    private(set) var requestCount = 0
    private var liveGeneration = 0

    func setLiveGeneration(_ generation: Int) {
        liveGeneration = generation
    }

    func requestCandidatesWhileTyping(
        generation: Int,
        hiragana: String,
        leftSideContext: String?,
        options: AzooKeyFetchOptions
    ) async -> FetchRequestOutcome {
        guard generation == liveGeneration else { return .abortedBeforeFetch }
        requestCount += 1
        lastRichCandidates = true
        return .success([.text("漢字")])
    }

    func requestCandidates(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool,
        options: AzooKeyFetchOptions
    ) -> [AzooKeyCandidate] {
        requestCount += 1
        lastRichCandidates = richCandidates
        return [.text("漢字")]
    }

    func peekCachedCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> AzooKeyCachePeek? {
        nil
    }

    func commit(reading: String, text: String) { _ = (reading, text) }

    func lcidForCommitted(reading: String, output: String) -> Int? { nil }

    func canonicalReading(for reading: String, text: String) -> String? { nil }
}
