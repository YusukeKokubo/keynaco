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

    /// was_explicit=true（ユーザーが手で navigate）なら rescuedBy=nil（真の UX 損失）。
    func testRescuedByNilWhenUserExplicit() {
        let record = CandidateDivergenceRecord(
            ts: 0, reading: "はし", z1: "はし", confirmed: "箸",
            selectedRow: 1, wasExplicit: true,
            candidates: ["はし", "箸"], leftContext: nil,
            confirmedSource: "dict", initialRow: 0,
            initialRowReason: "azooKey"
        )
        XCTAssertNil(record.rescuedBy)
        XCTAssertNil(record.asDictionary()["rescued_by"] as? String)
    }

    /// was_explicit=false なら rescuedBy = confirmedSource（履歴/辞書が救った）。
    func testRescuedByEqualsConfirmedSourceWhenAuto() {
        let record = CandidateDivergenceRecord(
            ts: 0, reading: "しょり", z1: "しょり", confirmed: "処理",
            selectedRow: 0, wasExplicit: false,
            candidates: ["処理", "しょり"], leftContext: nil,
            confirmedSource: "history", initialRow: 0,
            initialRowReason: "exactMatchHistory"
        )
        XCTAssertEqual(record.rescuedBy, "history")
        XCTAssertEqual(record.asDictionary()["rescued_by"] as? String, "history")
    }

    /// scoredSources が divergence_log JSON に含まれる（score 設計の事後シミュレーション用）。
    func testScoredSourcesEmittedInDictionary() {
        let record = CandidateDivergenceRecord(
            ts: 0, reading: "あい", z1: "愛", confirmed: "藍",
            selectedRow: 1, wasExplicit: true,
            candidates: ["愛", "藍"], leftContext: nil,
            confirmedSource: "dict", initialRow: 0, initialRowReason: "scoreOrder",
            scoredSources: ["azooKey(0):愛(10.00)", "userDictExact:藍(50.00)"]
        )
        let dict = record.asDictionary()
        XCTAssertEqual(dict["scored_sources"] as? [String],
                       ["azooKey(0):愛(10.00)", "userDictExact:藍(50.00)"])
    }

    /// scoredSources が nil なら JSON キーごと省略（後方互換）。
    func testScoredSourcesOmittedWhenNil() {
        let record = CandidateDivergenceRecord(
            ts: 0, reading: "あい", z1: "愛", confirmed: "藍",
            selectedRow: 1, wasExplicit: true,
            candidates: ["愛", "藍"], leftContext: nil,
            confirmedSource: "dict", initialRow: 0, initialRowReason: "scoreOrder"
        )
        XCTAssertNil(record.asDictionary()["scored_sources"])
    }

    /// confirmedSource が空文字なら rescuedBy=nil（旧形式互換）。
    func testRescuedByNilWhenSourceEmpty() {
        let record = CandidateDivergenceRecord(
            ts: 0, reading: "x", z1: "a", confirmed: "b",
            selectedRow: 0, wasExplicit: false,
            candidates: ["a","b"], leftContext: nil,
            confirmedSource: "", initialRow: 0, initialRowReason: ""
        )
        XCTAssertNil(record.rescuedBy)
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
