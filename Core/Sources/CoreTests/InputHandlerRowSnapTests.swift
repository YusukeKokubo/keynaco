import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

/// 候補選択 row が確定直前に巻き戻る事象（async fetch の `.show` で row=0 にリセット等）の検出ロジック。
final class InputHandlerRowSnapTests: InputHandlerTestCase {

    // MARK: - maxObservedSelectedRow の更新

    func testMaxObservedSelectedRowTracksApply() {
        typeRomaji("kanzi")
        applyCandidateAction(handler.buildCandidateList(trigger: .explicit))
        XCTAssertEqual(handler.sessionTracker.maxObservedSelectedRow, 0)

        // ↓ 1 回で row 1 に進む
        press(keyCode: KeyCode.downArrow, candidateVisible: true)
        XCTAssertEqual(handler.sessionTracker.maxObservedSelectedRow, 1, "↓ 1 回で max=1")

        // さらに ↓ で row 2
        press(keyCode: KeyCode.downArrow, candidateVisible: true)
        XCTAssertEqual(handler.sessionTracker.maxObservedSelectedRow, 2, "↓ 2 回で max=2")

        // ↑ で row 1 に戻っても max は据え置き
        press(keyCode: KeyCode.upArrow, candidateVisible: true)
        XCTAssertEqual(handler.sessionTracker.maxObservedSelectedRow, 2, "↑ で戻っても max=2 のまま")
    }

    // MARK: - 巻き戻り検出

    /// row 1 まで動かしたあとに `.show` で row=0 にリセットされて Enter → row_snapped_back が立つ。
    func testRowSnappedBackAnomalyOnRebuildToRowZero() {
        typeRomaji("kanzi")
        applyCandidateAction(handler.buildCandidateList(trigger: .explicit))
        press(keyCode: KeyCode.downArrow, candidateVisible: true)
        XCTAssertEqual(handler.candidateSession.selectedRow, 1)
        XCTAssertEqual(handler.sessionTracker.maxObservedSelectedRow, 1)

        // async fetch race 等で `.show` が来て row=0 にリセットされた状態を作る
        applyCandidateAction(handler.buildCandidateList(trigger: .whileTyping))
        XCTAssertEqual(handler.candidateSession.selectedRow, 0, "rebuild で row=0 にスナップ")

        // 確定（候補リスト row=0 が selectedText="かんじ" だとして模擬）
        press(keyCode: KeyCode.enter, candidateVisible: true, selectedRow: 0, selectedText: "かんじ")
        guard let record = handler.pendingSessionRecord else {
            XCTFail("Enter 確定で pendingSessionRecord が生成されるはず"); return
        }
        XCTAssertTrue(record.anomaly.contains("row_snapped_back"),
                      "row 1 まで動かしたのに row=0 で確定したら row_snapped_back が立つはず: \(record.anomaly)")
        XCTAssertEqual(record.maxObservedSelectedRow, 1)
        XCTAssertEqual(record.candidateDepth, 0)
    }

    /// 同じ row で確定したケースでは anomaly は立たない。
    func testNoAnomalyWhenConfirmedAtMaxRow() {
        typeRomaji("kanzi")
        applyCandidateAction(handler.buildCandidateList(trigger: .explicit))
        press(keyCode: KeyCode.downArrow, candidateVisible: true)
        press(keyCode: KeyCode.enter, candidateVisible: true, selectedRow: 1, selectedText: "感じ")
        guard let record = handler.pendingSessionRecord else {
            XCTFail("Enter 確定で pendingSessionRecord が生成されるはず"); return
        }
        XCTAssertFalse(record.anomaly.contains("row_snapped_back"),
                       "max=row=1 のとき anomaly は立たない: \(record.anomaly)")
        XCTAssertEqual(record.maxObservedSelectedRow, 1)
    }

    /// scroll せずに row 0 で確定した通常パスでは anomaly も max_observed_row も出ない。
    func testNoAnomalyAndNoMaxRowFieldOnRowZeroConfirm() {
        typeRomaji("kanzi")
        applyCandidateAction(handler.buildCandidateList(trigger: .explicit))
        press(keyCode: KeyCode.enter, candidateVisible: true, selectedRow: 0, selectedText: "感じ")
        guard let record = handler.pendingSessionRecord else {
            XCTFail("Enter 確定で pendingSessionRecord が生成されるはず"); return
        }
        XCTAssertFalse(record.anomaly.contains("row_snapped_back"))
        XCTAssertEqual(record.maxObservedSelectedRow, 0)
        // JSON 出力では 0 のとき省略される
        let dict = record.asDictionary()
        XCTAssertNil(dict["max_observed_row"], "max=0 のときは省略")
    }

    /// JSON 出力に max_observed_row が乗る（>0 のとき）。
    func testMaxObservedRowAppearsInJSON() {
        typeRomaji("kanzi")
        applyCandidateAction(handler.buildCandidateList(trigger: .explicit))
        press(keyCode: KeyCode.downArrow, candidateVisible: true)
        press(keyCode: KeyCode.downArrow, candidateVisible: true)
        press(keyCode: KeyCode.enter, candidateVisible: true, selectedRow: 0, selectedText: "かんじ")
        guard let record = handler.pendingSessionRecord else {
            XCTFail("Enter 確定で pendingSessionRecord が生成されるはず"); return
        }
        let dict = record.asDictionary()
        XCTAssertEqual(dict["max_observed_row"] as? Int, 2)
        XCTAssertEqual(dict["anomaly"] as? [String], ["row_snapped_back"])
    }
}
