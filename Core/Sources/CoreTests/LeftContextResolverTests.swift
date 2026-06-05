import XCTest
@testable import KeynacoCore

final class LeftContextResolverTests: XCTestCase {

    private func resolve(
        sessionBuffer: String = "",
        imkBefore: String? = nil,
        cursorLocationAvailable: Bool = true
    ) -> String {
        LeftContextResolver.resolve(.init(
            sessionBuffer: sessionBuffer,
            imkBefore: imkBefore,
            cursorLocationAvailable: cursorLocationAvailable
        ))
    }

    func testSessionBufferOnly() {
        XCTAssertEqual(resolve(sessionBuffer: "とうきょうで"), "とうきょうで")
    }

    func testImkBeforeOnly() {
        XCTAssertEqual(resolve(imkBefore: "今日は会議の件で"), "今日は会議の件で")
    }

    func testCombinedSessionBufferAndBefore() {
        XCTAssertEqual(
            resolve(sessionBuffer: "東京", imkBefore: "今日は会議の件で"),
            "東京今日は会議の件で"
        )
    }

    func testBeforeTruncatedToMaxBeforeLength() {
        let longBefore = String(repeating: "あ", count: 350)
        let result = resolve(imkBefore: longBefore)
        XCTAssertEqual(result.count, LeftContextResolver.maxBeforeLength)
        XCTAssertEqual(result, String(longBefore.suffix(LeftContextResolver.maxBeforeLength)))
    }

    func testCombinedPreservesSessionBufferAndTrimsBefore() {
        let session = String(repeating: "確", count: 50)
        let longBefore = String(repeating: "文", count: 400)
        let result = resolve(sessionBuffer: session, imkBefore: longBefore)
        XCTAssertTrue(result.hasPrefix(session))
        // before は先に maxBeforeLength に切られてから結合される
        let beforePart = String(longBefore.suffix(LeftContextResolver.maxBeforeLength))
        let maxBefore = LeftContextResolver.maxCombinedLength - session.count
        let expectedBefore = String(beforePart.suffix(maxBefore))
        XCTAssertEqual(result, session + expectedBefore)
        XCTAssertEqual(result.count, session.count + expectedBefore.count)
    }

    func testCombinedDoesNotTruncateSessionBuffer() {
        let session = String(repeating: "歴", count: 100)
        let before = String(repeating: "前", count: 500)
        let result = resolve(sessionBuffer: session, imkBefore: before)
        XCTAssertTrue(result.hasPrefix(session))
        XCTAssertEqual(result.count, LeftContextResolver.maxCombinedLength)
    }

    func testCursorLocationUnavailableIgnoresImkBefore() {
        XCTAssertEqual(
            resolve(sessionBuffer: "バッファ", imkBefore: "IMK前文", cursorLocationAvailable: false),
            "バッファ"
        )
    }

    func testEmptyImkBeforeReturnsSessionBuffer() {
        XCTAssertEqual(resolve(sessionBuffer: "のみ", imkBefore: ""), "のみ")
        XCTAssertEqual(resolve(sessionBuffer: "のみ", imkBefore: nil), "のみ")
    }

    func testEmptyInputs() {
        XCTAssertEqual(resolve(), "")
    }

    func testSandboxInputFactory() {
        let input = LeftContextResolver.Input.sandbox(
            sessionBuffer: "報告書",
            documentBefore: "今日は"
        )
        XCTAssertEqual(LeftContextResolver.resolve(input), "報告書今日は")
        let emptyBefore = LeftContextResolver.Input.sandbox(sessionBuffer: "のみ", documentBefore: "")
        XCTAssertEqual(LeftContextResolver.resolve(emptyBefore), "のみ")
        let long = LeftContextResolver.resolve(.sandbox(
            sessionBuffer: "",
            documentBefore: String(repeating: "文", count: 500)
        ))
        XCTAssertEqual(long.count, LeftContextResolver.maxBeforeLength)
    }

    func testProductionInputFactory() {
        let noCursor = LeftContextResolver.Input.production(
            sessionBuffer: "buf", imkBefore: "前文", cursorLocationAvailable: false
        )
        XCTAssertEqual(LeftContextResolver.resolve(noCursor), "buf")
    }
}
