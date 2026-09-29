import XCTest
@testable import KeynacoCore

final class WhileTypingFetchRetentionTests: XCTestCase {

    private func input(
        pending: String? = "か",
        pendingContext: String? = "今日は",
        before: String = "か",
        after: String = "か",
        contextAfter: String? = "今日は",
        requested: String? = nil,
        consumed: Bool = true
    ) -> WhileTypingFetchRetention.Input {
        .init(
            pendingReading: pending,
            pendingLeftContext: pendingContext,
            composedHiraganaBefore: before,
            composedHiraganaAfter: after,
            leftContextAfter: contextAfter,
            requestedReading: requested,
            consumed: consumed
        )
    }

    /// 「か」予約後の子音キー `k`: 読みは「か」のまま → fetch を生かす。
    func testConsonantKeyKeepsPendingFetch() {
        XCTAssertTrue(WhileTypingFetchRetention.shouldKeepPending(input()))
    }

    /// 子音キーで handler が同じ読みを再要求しても生かす（再予約で捨てない）。
    func testSameReadingRequestKeepsPendingFetch() {
        XCTAssertTrue(WhileTypingFetchRetention.shouldKeepPending(input(requested: "か")))
    }

    /// 母音キーで「かき」に伸びた → 世代を進める。
    func testReadingChangeDropsPendingFetch() {
        XCTAssertFalse(WhileTypingFetchRetention.shouldKeepPending(input(after: "かき", requested: "かき")))
    }

    /// Backspace で読みが縮んだ → 世代を進める。
    func testBackspaceShrinkDropsPendingFetch() {
        XCTAssertFalse(WhileTypingFetchRetention.shouldKeepPending(input(pending: "かき", before: "かき", after: "か")))
    }

    func testNoPendingFetchAdvances() {
        XCTAssertFalse(WhileTypingFetchRetention.shouldKeepPending(input(pending: nil)))
    }

    func testLeftContextChangeDropsPendingFetch() {
        XCTAssertFalse(WhileTypingFetchRetention.shouldKeepPending(input(contextAfter: "明日は")))
    }

    /// 未消費キー（矢印・Cmd 等）は従来どおり世代を進める。
    func testUnconsumedKeyDropsPendingFetch() {
        XCTAssertFalse(WhileTypingFetchRetention.shouldKeepPending(input(consumed: false)))
    }

    /// Enter 確定等で組成が空になった → 世代を進める。
    func testCommitDropsPendingFetch() {
        XCTAssertFalse(WhileTypingFetchRetention.shouldKeepPending(input(after: "")))
    }
}
