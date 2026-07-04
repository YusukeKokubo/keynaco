import XCTest
@testable import KeynacoCore

final class AsyncCandidateArrivalTests: XCTestCase {

    func testShouldApplyRequiresMatchingGenerationAndReading() {
        let ok = AsyncCandidateArrival.ApplyContext(
            candidateGeneration: 3,
            arrivalGeneration: 3,
            reading: "かん",
            composedHiragana: "かん",
            isExplicitlySelected: false,
            isComposing: true
        )
        XCTAssertTrue(AsyncCandidateArrival.shouldApply(ok))

        XCTAssertFalse(AsyncCandidateArrival.shouldApply(AsyncCandidateArrival.ApplyContext(
            candidateGeneration: 2, arrivalGeneration: 3,
            reading: "かん", composedHiragana: "かん",
            isExplicitlySelected: false, isComposing: true
        )))
        XCTAssertFalse(AsyncCandidateArrival.shouldApply(AsyncCandidateArrival.ApplyContext(
            candidateGeneration: 3, arrivalGeneration: 3,
            reading: "かん", composedHiragana: "か",
            isExplicitlySelected: false, isComposing: true
        )))
        XCTAssertFalse(AsyncCandidateArrival.shouldApply(AsyncCandidateArrival.ApplyContext(
            candidateGeneration: 3, arrivalGeneration: 3,
            reading: "かん", composedHiragana: "かん",
            isExplicitlySelected: true, isComposing: true
        )))
        XCTAssertFalse(AsyncCandidateArrival.shouldApply(AsyncCandidateArrival.ApplyContext(
            candidateGeneration: 3, arrivalGeneration: 3,
            reading: "かん", composedHiragana: "かん",
            isExplicitlySelected: false, isComposing: false
        )))
    }

    func testApplyCandidateActionRestoresRowWhenTextStillPresent() {
        var session = CandidateSession()
        session.apply(.show(candidates: ["a", "b", "c"], fixedEnd: 0))
        session.apply(.selectNext)
        let preservation = AsyncCandidateArrival.rowPreservationSnapshot(from: session)

        AsyncCandidateArrival.applyCandidateAction(
            session: &session,
            action: .show(candidates: ["a", "b", "c"], fixedEnd: 0),
            preservation: preservation
        )

        XCTAssertEqual(session.selectedRow, 1)
        XCTAssertFalse(session.isExplicitlySelected)
    }

    func testApplyCandidateActionDoesNotRestoreWhenTextMoved() {
        var session = CandidateSession()
        session.apply(.show(candidates: ["a", "b"], fixedEnd: 0))
        session.apply(.selectNext)
        let preservation = AsyncCandidateArrival.rowPreservationSnapshot(from: session)

        AsyncCandidateArrival.applyCandidateAction(
            session: &session,
            action: .show(candidates: ["x", "y"], fixedEnd: 0),
            preservation: preservation
        )

        XCTAssertEqual(session.selectedRow, 0)
    }
}
