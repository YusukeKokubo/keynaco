import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

final class InputHandlerPostKeyDownTests: InputHandlerTestCase {

    func testProductionOverloadAppliesCandidateActionWhenNotConsumed() {
        handler.candidateSession.apply(
            .show(candidates: ["a", "b"], fixedEnd: 0)
        )
        var imkCache = handler.leftContextIMKCache
        handler.applyPostKeyDownCandidateAndIMK(
            consumed: false,
            action: .selectNext,
            client: client,
            composedHiraganaWasEmpty: true,
            didInsertText: false,
            imkCache: &imkCache,
            newIMKSnapshot: nil
        )
        handler.leftContextIMKCache = imkCache
        XCTAssertEqual(handler.candidateSession.selectedRow, 1)
        XCTAssertTrue(handler.candidateSession.isExplicitlySelected)
    }

    func testSandboxOverloadAlwaysAppliesCandidateAction() {
        handler.candidateSession.apply(
            .show(candidates: ["a", "b"], fixedEnd: 0)
        )
        handler.applyPostKeyDownCandidateAndIMK(action: .selectNext, client: client)
        XCTAssertEqual(handler.candidateSession.selectedRow, 1)
        XCTAssertTrue(handler.candidateSession.isExplicitlySelected)
    }

    func testProductionOverloadMaintainsIMKCacheWhenInvalidatedWithoutConsumption() {
        handler.leftContextIMKCache = .invalidated
        var imkCache = handler.leftContextIMKCache
        handler.applyPostKeyDownCandidateAndIMK(
            consumed: false,
            action: .none,
            client: client,
            composedHiraganaWasEmpty: true,
            didInsertText: false,
            imkCache: &imkCache,
            newIMKSnapshot: nil
        )
        handler.leftContextIMKCache = imkCache
        XCTAssertNil(handler.leftContextIMKCache.snapshot)
        XCTAssertFalse(handler.leftContextIMKCache.isInvalidated)
    }

    func testSandboxOverloadSkipsIMKMaintenance() {
        handler.leftContextIMKCache = .invalidated
        handler.applyPostKeyDownCandidateAndIMK(action: .none, client: client)
        XCTAssertTrue(handler.leftContextIMKCache.isInvalidated)
    }
}
