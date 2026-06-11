import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

final class InputHandlerPostKeyDownTests: InputHandlerTestCase {

    func testSkipsCandidateApplyWhenNotConsumedInProductionOverload() {
        handler.candidateSession.apply(
            .show(candidates: ["a"], historyEnd: 0, initialRow: 0, fixedEnd: 0)
        )
        handler.applyPostKeyDownCandidateAndIMK(
            consumed: false,
            action: .selectNext,
            client: client,
            composedHiraganaWasEmpty: true,
            didInsertText: false,
            imkCache: &handler.leftContextIMKCache,
            newIMKSnapshot: nil
        )
        XCTAssertEqual(handler.candidateSession.selectedRow, 0)
        XCTAssertFalse(handler.candidateSession.isExplicitlySelected)
    }

    func testSandboxOverloadAlwaysAppliesCandidateAction() {
        handler.candidateSession.apply(
            .show(candidates: ["a", "b"], historyEnd: 0, initialRow: 0, fixedEnd: 0)
        )
        handler.applyPostKeyDownCandidateAndIMK(
            consumed: false,
            action: .selectNext,
            client: client,
            composedHiraganaWasEmpty: true,
            didInsertText: false
        )
        XCTAssertEqual(handler.candidateSession.selectedRow, 1)
        XCTAssertTrue(handler.candidateSession.isExplicitlySelected)
    }

    func testProductionOverloadMaintainsIMKCacheWhenInvalidatedWithoutConsumption() {
        handler.leftContextIMKCache = LeftContextIMKCache(
            snapshot: IMKSurroundingSnapshot(location: 1, before: "x", after: ""),
            invalidated: true
        )
        handler.applyPostKeyDownCandidateAndIMK(
            consumed: false,
            action: .none,
            client: client,
            composedHiraganaWasEmpty: true,
            didInsertText: false,
            imkCache: &handler.leftContextIMKCache,
            newIMKSnapshot: nil
        )
        XCTAssertNil(handler.leftContextIMKCache.snapshot)
        XCTAssertFalse(handler.leftContextIMKCache.invalidated)
    }

    func testSandboxOverloadSkipsIMKMaintenance() {
        handler.leftContextIMKCache = LeftContextIMKCache(invalidated: true)
        handler.applyPostKeyDownCandidateAndIMK(
            consumed: false,
            action: .none,
            client: client,
            composedHiraganaWasEmpty: true,
            didInsertText: false
        )
        XCTAssertTrue(handler.leftContextIMKCache.invalidated)
    }
}
