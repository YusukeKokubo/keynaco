import XCTest
@testable import KeynacoCore

final class LeftContextResolverTests: XCTestCase {

    private func combine(
        sessionBuffer: String = "",
        imkBefore: String? = nil,
        cursorLocationAvailable: Bool = true
    ) -> String {
        LeftContextSource.combine(
            sessionBuffer: sessionBuffer,
            imkBefore: imkBefore,
            cursorLocationAvailable: cursorLocationAvailable
        )
    }

    func testBeforeOnlyWhenSessionEmpty() {
        XCTAssertEqual(combine(imkBefore: "前文"), "前文")
    }

    func testSessionOnlyWhenBeforeNil() {
        XCTAssertEqual(combine(sessionBuffer: "セッション"), "セッション")
    }

    func testSessionOnlyWhenBeforeEmpty() {
        XCTAssertEqual(combine(sessionBuffer: "セッション", imkBefore: ""), "セッション")
    }

    func testCombinedSessionAndBefore() {
        XCTAssertEqual(combine(sessionBuffer: "報告書", imkBefore: "今日は"), "報告書今日は")
    }

    func testBeforeTruncatedToMaxBeforeLength() {
        let longBefore = String(repeating: "あ", count: 350)
        let result = combine(imkBefore: longBefore)
        XCTAssertEqual(result.count, LeftContextSource.maxBeforeLength)
        XCTAssertEqual(result, String(longBefore.suffix(LeftContextSource.maxBeforeLength)))
    }

    func testCombinedTruncatedWhenSessionPlusBeforeExceedsMax() {
        let session = String(repeating: "あ", count: 100)
        let longBefore = String(repeating: "い", count: 350)
        let result = combine(sessionBuffer: session, imkBefore: longBefore)
        XCTAssertTrue(result.hasPrefix(session))
        let beforePart = String(longBefore.suffix(LeftContextSource.maxBeforeLength))
        let maxBefore = LeftContextSource.maxCombinedLength - session.count
        let expectedBefore = String(beforePart.suffix(maxBefore))
        XCTAssertEqual(result, session + expectedBefore)
    }

    func testCombinedTotalCappedAtMaxCombinedLength() {
        let session = String(repeating: "あ", count: 150)
        let before = String(repeating: "い", count: 300)
        let result = combine(sessionBuffer: session, imkBefore: before)
        XCTAssertTrue(result.hasPrefix(session))
        XCTAssertEqual(result.count, LeftContextSource.maxCombinedLength)
    }

    func testCursorUnavailableReturnsSessionOnly() {
        XCTAssertEqual(
            combine(sessionBuffer: "buf", imkBefore: "前文", cursorLocationAvailable: false),
            "buf"
        )
    }

    func testEmptyInputs() {
        XCTAssertEqual(combine(), "")
        XCTAssertEqual(combine(imkBefore: ""), "")
        XCTAssertEqual(combine(sessionBuffer: "", imkBefore: "x"), "x")
    }
}
