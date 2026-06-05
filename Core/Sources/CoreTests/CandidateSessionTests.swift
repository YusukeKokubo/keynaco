import XCTest
@testable import KeynacoCore

final class CandidateSessionTests: XCTestCase {

    func testShowAndDismiss() {
        var s = CandidateSession()
        s.apply(.show(candidates: ["a", "b"], historyEnd: 0, initialRow: 1, fixedEnd: 0, zenzaiRow: nil))
        XCTAssertTrue(s.isVisible)
        XCTAssertEqual(s.selectedRow, 1)
        XCTAssertEqual(s.selectedText, "b")
        s.apply(.dismiss)
        XCTAssertFalse(s.isVisible)
        XCTAssertTrue(s.candidates.isEmpty)
    }

    func testSelectNextWraps() {
        var s = CandidateSession()
        s.apply(.show(candidates: ["a", "b"], historyEnd: 0, initialRow: 0, fixedEnd: 0))
        s.apply(.selectNext)
        XCTAssertEqual(s.selectedRow, 1)
        XCTAssertTrue(s.isExplicitlySelected)
        s.apply(.selectNext)
        XCTAssertEqual(s.selectedRow, 0)
    }

    func testDeleteSelectedShrinksHistoryEnd() {
        var s = CandidateSession()
        s.apply(.show(candidates: ["fix", "hist"], historyEnd: 2, initialRow: 1, fixedEnd: 1))
        s.apply(.deleteSelected)
        XCTAssertEqual(s.candidates, ["fix"])
        XCTAssertEqual(s.historyEnd, 1)
    }
}
