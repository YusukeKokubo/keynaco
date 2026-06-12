import XCTest
import KeynacoCore
@testable import keynaco

final class CandidateTablePatchTests: XCTestCase {

    func testNoopWhenIdentical() {
        let snap = panel(["かんじ", "カンジ", "漢字"])
        XCTAssertEqual(CandidateTablePatchPlanner.plan(old: snap, new: snap), .noop)
    }

    func testIncrementalAppendTail() {
        let old = panel(["かんじ", "カンジ"])
        let new = panel(["かんじ", "カンジ", "漢字", "感じ"])
        XCTAssertEqual(
            CandidateTablePatchPlanner.plan(old: old, new: new),
            .incremental(prefixLength: 2, removeTailCount: 0, insertTailCount: 2, reloadPrefixRows: [])
        )
    }

    func testReloadAllWhenPrefixMismatch() {
        let old = panel(["漢", "感"])
        let new = panel(["かんじ", "カンジ", "漢字"])
        XCTAssertEqual(CandidateTablePatchPlanner.plan(old: old, new: new), .reloadAll)
    }

    func testMetadataOnlyReload() {
        let old = CandidatePanelSnapshot(
            rows: [
                row("かんじ"),
                row("漢字", isHistory: false),
            ],
            selectedRow: 0
        )
        let new = CandidatePanelSnapshot(
            rows: [
                row("かんじ"),
                row("漢字", isHistory: true, sectionLabel: "履歴", showsSectionDivider: true),
            ],
            selectedRow: 0
        )
        XCTAssertEqual(
            CandidateTablePatchPlanner.plan(old: old, new: new),
            .incremental(prefixLength: 2, removeTailCount: 0, insertTailCount: 0, reloadPrefixRows: [1])
        )
    }

    private func panel(_ candidates: [String]) -> CandidatePanelSnapshot {
        var session = CandidateSession()
        session.apply(.show(
            candidates: candidates,
            historyEnd: 0,
            initialRow: 0,
            fixedEnd: min(2, candidates.count)
        ))
        return CandidatePanelSnapshot(model: CandidatePanelModel(session: session))
    }

    private func row(
        _ text: String,
        isHistory: Bool = false,
        sectionLabel: String = "",
        showsSectionDivider: Bool = false
    ) -> CandidateRowSnapshot {
        CandidateRowSnapshot(
            text: text,
            showsDelete: isHistory,
            isHistory: isHistory,
            sectionLabel: sectionLabel,
            showsSectionDivider: showsSectionDivider
        )
    }
}
