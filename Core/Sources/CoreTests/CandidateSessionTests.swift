import XCTest
@testable import KeynacoCore

final class CandidateSessionTests: XCTestCase {

    func testShowAndDismiss() {
        var s = CandidateSession()
        s.apply(.show(candidates: ["a", "b"], fixedEnd: 0))
        XCTAssertTrue(s.isVisible)
        XCTAssertEqual(s.selectedRow, 0)
        XCTAssertEqual(s.selectedText, "a")
        s.apply(.dismiss)
        XCTAssertFalse(s.isVisible)
        XCTAssertTrue(s.candidates.isEmpty)
    }

    func testSelectNextWraps() {
        var s = CandidateSession()
        s.apply(.show(candidates: ["a", "b"], fixedEnd: 0))
        s.apply(.selectNext)
        XCTAssertEqual(s.selectedRow, 1)
        XCTAssertTrue(s.isExplicitlySelected)
        s.apply(.selectNext)
        XCTAssertEqual(s.selectedRow, 0)
    }

    func testPanelInteractionPhases() {
        var s = CandidateSession()
        XCTAssertEqual(s.panelInteraction, .hidden)
        s.apply(.show(candidates: ["a"], fixedEnd: 0))
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
            fixedEnd: 1,
            candidateSources: [.hiraganaBuiltin, .historyExact]
        ))
        s.selectedRow = 1
        s.apply(.deleteSelected)
        XCTAssertEqual(s.candidates, ["fix"])
        XCTAssertEqual(s.candidateSources, [.hiraganaBuiltin])
    }

    func testExplicitRequiresVisible() {
        var s = CandidateSession()
        s.apply(.show(candidates: [], fixedEnd: 0, initialIsExplicitlySelected: true))
        XCTAssertFalse(s.isVisible)
        XCTAssertFalse(s.isExplicitlySelected)
    }

    func testSetBracketCandidatesNilEndsBracketMode() {
        var s = CandidateSession()
        s.beginBracketMode(options: ["「", "【"])
        s.apply(.show(candidates: ["「", "【"], fixedEnd: 0))
        XCTAssertTrue(s.isBracketMode)
        s.setBracketCandidates(nil)
        XCTAssertFalse(s.isBracketMode)
        XCTAssertFalse(s.isVisible)
        XCTAssertTrue(s.candidates.isEmpty)
    }

    func testEndBracketModeClosesPanel() {
        var s = CandidateSession()
        s.beginBracketMode(options: ["("])
        s.apply(.show(candidates: ["("], fixedEnd: 0))
        s.endBracketMode()
        XCTAssertFalse(s.isBracketMode)
        XCTAssertFalse(s.isVisible)
    }
}
