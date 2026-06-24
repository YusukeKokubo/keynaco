import XCTest
@testable import keynaco
import KeynacoCore

final class AzooKeyFooterStatusTests: XCTestCase {

    private func session(
        visible: Bool = true,
        candidates: [String] = [],
        bracketCandidates: [String]? = nil
    ) -> CandidateSession {
        var s = CandidateSession()
        s.candidates = candidates
        s.isVisible = visible
        s.bracketCandidates = bracketCandidates
        return s
    }

    func testHiddenWhenNotVisible() {
        let s = session(visible: false, candidates: ["漢字"])
        XCTAssertNil(AzooKeyFooterStatus.resolve(session: s, isAzooKeyPending: false))
    }

    func testHiddenInBracketMode() {
        let s = session(candidates: ["("], bracketCandidates: ["(", ")"])
        XCTAssertNil(AzooKeyFooterStatus.resolve(session: s, isAzooKeyPending: false))
    }

    func testHiddenWhenIdle() {
        let s = session(candidates: ["かんじ", "漢字"])
        XCTAssertNil(AzooKeyFooterStatus.resolve(session: s, isAzooKeyPending: false))
    }

    func testFetchingWhenPending() {
        let s = session(candidates: ["かんじ", "カンジ"])
        XCTAssertEqual(
            AzooKeyFooterStatus.resolve(session: s, isAzooKeyPending: true),
            .fetching
        )
    }

    func testIsAzooKeyPendingBeforeSchedulerStarts() {
        let s = session(candidates: ["かんじ", "カンジ"])
        XCTAssertTrue(
            AzooKeyFooterStatus.isAzooKeyPending(pendingReading: "かんじ", schedulerPending: false)
        )
        XCTAssertEqual(
            AzooKeyFooterStatus.resolve(
                session: s,
                isAzooKeyPending: AzooKeyFooterStatus.isAzooKeyPending(
                    pendingReading: "かんじ",
                    schedulerPending: false
                )
            ),
            .fetching
        )
    }

    func testIsAzooKeyPendingWithProvisionalCandidates() {
        let s = session(candidates: ["かん", "漢"])
        XCTAssertTrue(
            AzooKeyFooterStatus.isAzooKeyPending(pendingReading: "かんじ", schedulerPending: false)
        )
        XCTAssertEqual(
            AzooKeyFooterStatus.resolve(session: s, isAzooKeyPending: true),
            .fetching
        )
    }

    func testIsAzooKeyPendingFalseWhenIdle() {
        XCTAssertFalse(
            AzooKeyFooterStatus.isAzooKeyPending(pendingReading: nil, schedulerPending: false)
        )
    }

    func testIsAzooKeyPendingWhenSchedulerHasWork() {
        XCTAssertTrue(
            AzooKeyFooterStatus.isAzooKeyPending(pendingReading: nil, schedulerPending: true)
        )
    }

    func testRawValue() {
        XCTAssertEqual(AzooKeyFooterStatus.fetching.rawValue, "fetching")
    }
}
