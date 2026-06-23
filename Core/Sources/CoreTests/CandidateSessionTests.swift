import XCTest
@testable import KeynacoCore

final class CandidateSessionTests: XCTestCase {

    func testShowAndDismiss() {
        var s = CandidateSession()
        s.apply(.show(candidates: ["a", "b"], initialRow: 1, fixedEnd: 0))
        XCTAssertTrue(s.isVisible)
        XCTAssertEqual(s.selectedRow, 1)
        XCTAssertEqual(s.selectedText, "b")
        s.apply(.dismiss)
        XCTAssertFalse(s.isVisible)
        XCTAssertTrue(s.candidates.isEmpty)
    }

    func testSelectNextWraps() {
        var s = CandidateSession()
        s.apply(.show(candidates: ["a", "b"], initialRow: 0, fixedEnd: 0))
        s.apply(.selectNext)
        XCTAssertEqual(s.selectedRow, 1)
        XCTAssertTrue(s.isExplicitlySelected)
        s.apply(.selectNext)
        XCTAssertEqual(s.selectedRow, 0)
    }

    func testPanelInteractionPhases() {
        var s = CandidateSession()
        XCTAssertEqual(s.panelInteraction, .hidden)
        s.apply(.show(candidates: ["a"], initialRow: 0, fixedEnd: 0))
        XCTAssertEqual(s.panelInteraction, .passive)
        s.apply(.selectNext)
        XCTAssertEqual(s.panelInteraction, .explicit)
        s.apply(.dismiss)
        XCTAssertEqual(s.panelInteraction, .hidden)
    }

    func testDeleteSelectedRemovesHistoryRow() {
        var s = CandidateSession()
        s.apply(.show(
            candidates: ["fix", "hist"],
            initialRow: 1,
            fixedEnd: 1,
            candidateSources: [.hiraganaBuiltin, .historyExact]
        ))
        s.apply(.deleteSelected)
        XCTAssertEqual(s.candidates, ["fix"])
        XCTAssertEqual(s.candidateSources, [.hiraganaBuiltin])
    }
}
