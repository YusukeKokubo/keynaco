import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

final class CandidateDivergenceTests: InputHandlerTestCase {

    private func showCandidates(
        _ candidates: [String],
        initialRow: Int,
        apiOrder: [String],
        isExplicit: Bool
    ) {
        handler.candidateSession.apply(.show(
            candidates: candidates,
            historyEnd: 0,
            initialRow: initialRow,
            fixedEnd: 0,
            azooKeyApiOrder: apiOrder,
            initialIsExplicitlySelected: isExplicit
        ))
    }

    /// Z1（azooKeyApiOrder.first）と実確定が違うとき、pendingDivergenceRecord に 1 件残る。
    func testDivergenceRecordedWhenZ1AndConfirmedDiffer() {
        typeRomaji("yabai")
        showCandidates(
            ["やばい", "ヤバイ", "ヤバい"],
            initialRow: 1,
            apiOrder: ["やばい", "ヤバイ", "ヤバい"],
            isExplicit: true
        )
        let ctx = handler.candidateSession.makeContext()
        handler.commitComposition(client: client, candidate: ctx, trigger: .enter)
        guard let record = handler.pendingDivergenceRecord else {
            XCTFail("divergence record が記録されてない"); return
        }
        XCTAssertEqual(record.z1, "やばい")
        XCTAssertEqual(record.confirmed, "ヤバイ")
        XCTAssertEqual(record.selectedRow, 1)
        XCTAssertTrue(record.wasExplicit)
    }

    /// Z1 と実確定が一致してたら記録しない。
    func testNoDivergenceWhenZ1Confirmed() {
        typeRomaji("yabai")
        showCandidates(
            ["やばい", "ヤバイ"],
            initialRow: 0,
            apiOrder: ["やばい", "ヤバイ"],
            isExplicit: false
        )
        let ctx = handler.candidateSession.makeContext()
        handler.commitComposition(client: client, candidate: ctx, trigger: .enter)
        XCTAssertNil(handler.pendingDivergenceRecord,
                     "Z1 == confirmed なら記録対象外")
    }

    /// Zenzai 無効・文脈なしのとき（azooKeyApiOrder 空）は記録しない。
    func testNoDivergenceWhenApiOrderEmpty() {
        typeRomaji("yabai")
        showCandidates(
            ["やばい", "ヤバイ"],
            initialRow: 1,
            apiOrder: [],
            isExplicit: true
        )
        let ctx = handler.candidateSession.makeContext()
        handler.commitComposition(client: client, candidate: ctx, trigger: .enter)
        XCTAssertNil(handler.pendingDivergenceRecord,
                     "azooKeyApiOrder が空 = Zenzai 文脈未確定 のとき記録対象外")
    }
}
