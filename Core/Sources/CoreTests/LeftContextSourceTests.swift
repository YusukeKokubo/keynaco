import XCTest
@testable import KeynacoCore

final class LeftContextSourceTests: XCTestCase {

    // MARK: - Production

    func testProductionCacheHit() {
        let assembly = LeftContextSource.assembleProduction(
            sessionBuffer: "東京",
            cursorLocation: 10,
            cachedSurrounding: (location: 10, before: "今日は")
        )
        XCTAssertFalse(assembly.shouldClearCache)
        XCTAssertEqual(
            LeftContextResolver.resolve(assembly.input),
            "東京今日は"
        )
    }

    func testProductionLocationMismatchClearsCache() {
        let assembly = LeftContextSource.assembleProduction(
            sessionBuffer: "buf",
            cursorLocation: 5,
            cachedSurrounding: (location: 10, before: "前文")
        )
        XCTAssertTrue(assembly.shouldClearCache)
        XCTAssertEqual(LeftContextResolver.resolve(assembly.input), "buf")
    }

    func testProductionEmptyBeforeDoesNotUseCache() {
        let assembly = LeftContextSource.assembleProduction(
            sessionBuffer: "のみ",
            cursorLocation: 3,
            cachedSurrounding: (location: 3, before: "")
        )
        XCTAssertTrue(assembly.shouldClearCache)
        XCTAssertEqual(LeftContextResolver.resolve(assembly.input), "のみ")
    }

    func testProductionNoCache() {
        let assembly = LeftContextSource.assembleProduction(
            sessionBuffer: "session",
            cursorLocation: 1,
            cachedSurrounding: nil
        )
        XCTAssertFalse(assembly.shouldClearCache)
        XCTAssertEqual(LeftContextResolver.resolve(assembly.input), "session")
    }

    func testProductionCursorUnavailable() {
        let assembly = LeftContextSource.assembleProduction(
            sessionBuffer: "buf",
            cursorLocation: NSNotFound,
            cachedSurrounding: (location: 0, before: "ignored")
        )
        XCTAssertFalse(assembly.shouldClearCache)
        XCTAssertEqual(LeftContextResolver.resolve(assembly.input), "buf")
    }

    // MARK: - Sandbox

    func testSandboxResolveFromDocumentBefore() {
        let result = LeftContextSource.resolveSandbox(
            sessionBuffer: "報告書",
            documentBefore: "今日は"
        )
        XCTAssertEqual(result, "報告書今日は")
    }

    func testSandboxOverrideBypassesResolver() {
        let result = LeftContextSource.resolveSandbox(
            sessionBuffer: "ignored",
            documentBefore: "ignored",
            override: "fixed-context"
        )
        XCTAssertEqual(result, "fixed-context")
    }

    func testSandboxEmptyDocumentBefore() {
        let result = LeftContextSource.resolveSandbox(
            sessionBuffer: "のみ",
            documentBefore: ""
        )
        XCTAssertEqual(result, "のみ")
    }
}
