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

    /// 「か」予約中に子音キー（読み不変）が来ても fetch は生き残り onComplete まで届く（PLAN260929a）。
    func testConsonantKeyKeepsScheduledFetch() async {
        let scheduler = AzooKeyAsyncScheduler()
        let stub = RichFlagStub()
        let gen = scheduler.onKeyDown(converter: stub)
        var completed = false
        scheduler.schedule(
            generation: gen,
            reading: "か",
            leftSideContext: nil,
            converter: stub,
            debounceNanoseconds: 30_000_000
        ) { _ in completed = true }

        scheduler.recordKeyDown()
        let settled = scheduler.settleKeyDown(
            composedHiraganaBefore: "か",
            composedHiraganaAfter: "か",
            leftContextAfter: nil,
            requestedReading: nil,
            consumed: true,
            converter: stub
        )
        XCTAssertTrue(settled.keptPending)
        XCTAssertEqual(settled.generation, gen)

        _ = await scheduler.waitUntilIdle(timeoutNanoseconds: 500_000_000)
        XCTAssertTrue(completed)
        XCTAssertEqual(stub.requestCount, 1)
    }

    /// 読みが変わるキーは従来どおり世代を進め、予約中の fetch を捨てる。
    func testReadingChangeDropsScheduledFetch() async {
        let scheduler = AzooKeyAsyncScheduler()
        let stub = RichFlagStub()
        let gen = scheduler.onKeyDown(converter: stub)
        var completed = false
        scheduler.schedule(
            generation: gen,
            reading: "か",
            leftSideContext: nil,
            converter: stub,
            debounceNanoseconds: 30_000_000
        ) { _ in completed = true }

        scheduler.recordKeyDown()
        let settled = scheduler.settleKeyDown(
            composedHiraganaBefore: "か",
            composedHiraganaAfter: "かき",
            leftContextAfter: nil,
            requestedReading: "かき",
            consumed: true,
            converter: stub
        )
        XCTAssertFalse(settled.keptPending)
        XCTAssertEqual(settled.generation, gen + 1)
        XCTAssertFalse(scheduler.hasPendingWork)

        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(completed)
        XCTAssertEqual(stub.requestCount, 0)
    }

    /// キャンセル済みの古いタスクが、後から予約した新しいタスクの pending 状態を消さない。
    func testCancelledTaskDoesNotClearNewerSchedule() async {
        let scheduler = AzooKeyAsyncScheduler()
        let stub = RichFlagStub()
        let gen1 = scheduler.onKeyDown(converter: stub)
        scheduler.schedule(
            generation: gen1, reading: "か", leftSideContext: nil, converter: stub,
            debounceNanoseconds: 10_000_000
        ) { _ in }
        let gen2 = scheduler.onKeyDown(converter: stub)
        scheduler.schedule(
            generation: gen2, reading: "かき", leftSideContext: nil, converter: stub,
            debounceNanoseconds: 200_000_000
        ) { _ in }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(scheduler.hasPendingWork)
        XCTAssertEqual(scheduler.pendingReading, "かき")
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
