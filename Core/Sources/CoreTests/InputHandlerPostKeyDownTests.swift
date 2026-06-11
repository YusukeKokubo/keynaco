import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

final class InputHandlerPostKeyDownTests: InputHandlerTestCase {

    func testSkipsCandidateApplyWhenNotConsumedAndProductionPolicy() {
        handler.candidateSession.apply(
            .show(candidates: ["a"], historyEnd: 0, initialRow: 0, fixedEnd: 0)
        )
        var cache: LeftContextIMKCache? = nil
        handler.applyPostKeyDownEffects(
            consumed: false,
            action: .selectNext,
            client: client,
            composedHiraganaWasEmpty: true,
            didInsertText: false,
            alwaysApplyCandidateAction: false,
            imkCache: &cache,
            newIMKSnapshot: nil
        )
        XCTAssertEqual(handler.candidateSession.selectedRow, 0)
        XCTAssertFalse(handler.candidateSession.isExplicitlySelected)
    }

    func testAlwaysApplyCandidateActionForSandboxPolicy() {
        handler.candidateSession.apply(
            .show(candidates: ["a", "b"], historyEnd: 0, initialRow: 0, fixedEnd: 0)
        )
        var cache: LeftContextIMKCache? = nil
        handler.applyPostKeyDownEffects(
            consumed: false,
            action: .selectNext,
            client: client,
            composedHiraganaWasEmpty: true,
            didInsertText: false,
            alwaysApplyCandidateAction: true,
            imkCache: &cache,
            newIMKSnapshot: nil
        )
        XCTAssertEqual(handler.candidateSession.selectedRow, 1)
        XCTAssertTrue(handler.candidateSession.isExplicitlySelected)
    }

    func testMaintainsIMKCacheWhenInvalidatedWithoutConsumption() {
        var cache: LeftContextIMKCache? = LeftContextIMKCache(
            snapshot: IMKSurroundingSnapshot(location: 1, before: "x", after: ""),
            invalidated: true
        )
        handler.leftContextIMKCache = cache!
        handler.applyPostKeyDownEffects(
            consumed: false,
            action: .none,
            client: client,
            composedHiraganaWasEmpty: true,
            didInsertText: false,
            alwaysApplyCandidateAction: false,
            imkCache: &cache,
            newIMKSnapshot: nil
        )
        XCTAssertNil(cache?.snapshot)
        XCTAssertFalse(cache?.invalidated ?? true)
    }

    func testSkipsIMKMaintenanceWhenCacheNil() {
        handler.leftContextIMKCache = LeftContextIMKCache(invalidated: true)
        var cache: LeftContextIMKCache? = nil
        handler.applyPostKeyDownEffects(
            consumed: false,
            action: .none,
            client: client,
            composedHiraganaWasEmpty: true,
            didInsertText: false,
            alwaysApplyCandidateAction: false,
            imkCache: &cache,
            newIMKSnapshot: nil
        )
        XCTAssertTrue(handler.leftContextIMKCache.invalidated)
    }
}
