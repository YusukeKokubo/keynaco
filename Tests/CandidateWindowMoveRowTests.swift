import XCTest
@testable import keynaco

/// `CandidateWindow.moveRow(from:)` のセクション境界更新（F1 並べ替え）
@MainActor
final class CandidateWindowMoveRowTests: XCTestCase {

    func testMoveRow_fromHistoryBand_promotesToHistoryHead() {
        let w = CandidateWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        let cands = ["f0", "f1", "p0", "p1", "h0", "h1", "h2", "d0"]
        w.show(candidates: cands, historySectionEnd: 7, initialRow: 2, predictionEnd: 4, fixedSectionEnd: 2, near: .zero)

        w.moveRow(from: 5)

        XCTAssertEqual(
            w.candidates,
            ["f0", "f1", "p0", "p1", "h1", "h0", "h2", "d0"],
            "履歴帯の2番目を履歴先頭へ")
    }

    func testMoveRow_fromAzooBand_promotesToHistoryHead() {
        let w = CandidateWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        let cands = ["f0", "f1", "p0", "p1", "h0", "h1", "h2", "d0"]
        w.show(candidates: cands, historySectionEnd: 7, initialRow: 2, predictionEnd: 4, fixedSectionEnd: 2, near: .zero)

        w.moveRow(from: 7)

        XCTAssertEqual(
            w.candidates,
            ["f0", "f1", "p0", "p1", "d0", "h0", "h1", "h2"],
            "辞書帯を履歴先頭へ")
    }

    func testMoveRow_sameAsDestination_noOp() {
        let w = CandidateWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        let cands = ["f0", "f1", "p0", "p1", "h0", "h1", "h2", "d0"]
        w.show(candidates: cands, historySectionEnd: 7, initialRow: 4, predictionEnd: 4, fixedSectionEnd: 2, near: .zero)

        w.moveRow(from: 4)

        XCTAssertEqual(w.candidates, cands)
    }

    func testMoveRow_rejectsPredictionRow() {
        let w = CandidateWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        let cands = ["f0", "f1", "p0", "p1", "h0", "h1", "h2"]
        w.show(candidates: cands, historySectionEnd: 7, initialRow: 2, predictionEnd: 4, fixedSectionEnd: 2, near: .zero)

        w.moveRow(from: 3)

        XCTAssertEqual(w.candidates, cands)
    }
}
