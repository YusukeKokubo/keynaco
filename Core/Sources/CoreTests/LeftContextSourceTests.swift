import XCTest
@testable import KeynacoCore

final class LeftContextSourceTests: XCTestCase {

    // MARK: - Production

    func testProductionCacheHit() {
        var cache: LeftContextIMKCache = .valid(IMKSurroundingSnapshot(
            location: 10, before: "今日は", after: ""
        ))
        let ctx = LeftContextSource.resolveProduction(
            sessionBuffer: "東京",
            cache: &cache,
            cursorLocation: 10
        )
        XCTAssertEqual(ctx.combined, "東京今日は")
        XCTAssertEqual(ctx.imkBefore, "今日は")
        XCTAssertNotNil(cache.snapshot)
    }

    func testProductionLocationMismatchClearsCache() {
        var cache: LeftContextIMKCache = .valid(IMKSurroundingSnapshot(
            location: 3, before: "前文", after: ""
        ))
        let ctx = LeftContextSource.resolveProduction(
            sessionBuffer: "buf",
            cache: &cache,
            cursorLocation: 5
        )
        XCTAssertEqual(ctx.combined, "buf")
        XCTAssertNil(cache.snapshot)
    }

    func testProductionEmptyBeforeClearsCache() {
        var cache: LeftContextIMKCache = .valid(IMKSurroundingSnapshot(
            location: 3, before: "", after: ""
        ))
        let ctx = LeftContextSource.resolveProduction(
            sessionBuffer: "のみ",
            cache: &cache,
            cursorLocation: 3
        )
        XCTAssertEqual(ctx.combined, "のみ")
        XCTAssertNil(cache.snapshot)
    }

    func testProductionNoCache() {
        var cache = LeftContextIMKCache()
        let ctx = LeftContextSource.resolveProduction(
            sessionBuffer: "session",
            cache: &cache,
            cursorLocation: 1
        )
        XCTAssertEqual(ctx.combined, "session")
        XCTAssertNil(cache.snapshot)
    }

    func testProductionCursorUnavailable() {
        var cache: LeftContextIMKCache = .valid(IMKSurroundingSnapshot(
            location: 1, before: "前文", after: ""
        ))
        let ctx = LeftContextSource.resolveProduction(
            sessionBuffer: "buf",
            cache: &cache,
            cursorLocation: NSNotFound
        )
        XCTAssertEqual(ctx.combined, "buf")
        XCTAssertNotNil(cache.snapshot, "cursor 不可でもキャッシュは触らない")
    }

    // MARK: - applyPostKeyDown

    func testApplyPostKeyDownConsumesInvalidated() {
        var cache: LeftContextIMKCache = .invalidated
        LeftContextSource.applyPostKeyDown(
            cache: &cache,
            composedHiraganaEmpty: false,
            composedHiraganaWasEmpty: false,
            newSnapshot: nil
        )
        XCTAssertNil(cache.snapshot)
        XCTAssertFalse(cache.isInvalidated)
    }

    func testApplyPostKeyDownClearsOnEmptyComposition() {
        var cache: LeftContextIMKCache = .valid(IMKSurroundingSnapshot(
            location: 1, before: "x", after: ""
        ))
        LeftContextSource.applyPostKeyDown(
            cache: &cache,
            composedHiraganaEmpty: true,
            composedHiraganaWasEmpty: false,
            newSnapshot: nil
        )
        XCTAssertNil(cache.snapshot)
    }

    func testApplyPostKeyDownStoresNewSnapshotOnFirstComposition() {
        var cache = LeftContextIMKCache()
        let snap = IMKSurroundingSnapshot(location: 5, before: "前文", after: "後文")
        LeftContextSource.applyPostKeyDown(
            cache: &cache,
            composedHiraganaEmpty: false,
            composedHiraganaWasEmpty: true,
            newSnapshot: snap
        )
        XCTAssertEqual(cache.snapshot, snap)
    }

    func testResetCache() {
        var cache: LeftContextIMKCache = .invalidated
        LeftContextSource.resetCache(&cache)
        XCTAssertEqual(cache, LeftContextIMKCache())
    }

    // MARK: - Sandbox

    func testSandboxResolveFromDocumentBefore() {
        let ctx = LeftContextSource.resolveSandbox(
            sessionBuffer: "報告書",
            documentBefore: "今日は"
        )
        XCTAssertEqual(ctx.combined, "報告書今日は")
        XCTAssertEqual(ctx.imkBefore, "今日は")
    }

    func testSandboxOverrideBypassesResolver() {
        let ctx = LeftContextSource.resolveSandbox(
            sessionBuffer: "ignored",
            documentBefore: "ignored",
            override: "固定"
        )
        XCTAssertEqual(ctx.combined, "固定")
        XCTAssertNil(ctx.imkBefore)
    }

    func testSandboxEmptyDocumentBefore() {
        let ctx = LeftContextSource.resolveSandbox(
            sessionBuffer: "のみ",
            documentBefore: ""
        )
        XCTAssertEqual(ctx.combined, "のみ")
        XCTAssertNil(ctx.imkBefore)
    }
}
