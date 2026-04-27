import XCTest
@testable import keynaco

// See: docs/domain/states.md#候補選択中
// See: docs/domain/glossary.md#fixedcount
// See: docs/domain/glossary.md#historyend
// See: docs/domain/scenarios.md#s-02-候補選択と右矢印確定

final class InputHandlerCandidatesTests: InputHandlerTestCase {

    // MARK: - スペースで候補表示
    // See: docs/domain/states.md#候補選択中

    func testSpaceWithHiraganaShowsCandidates() {
        type(chars: "a", base: "a")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        guard case .show(let candidates, _, _) = action else {
            XCTFail("スペースで .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("あ"))
    }

    func testSpaceWithNothingPassesThrough() {
        XCTAssertFalse(press(keyCode: 49).consumed)
    }

    func testKatakanaAppearsInCandidatesOnSpace() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates[0], "あい", "先頭はひらがなのはず")
        XCTAssertEqual(candidates[1], "アイ", "2番目はカタカナのはず")
    }

    func testKatakanaInCandidatesWhenSpacePressed() {
        type(chars: "a", base: "a")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        guard case .show(let candidates, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.contains("ア"), "カタカナが候補に含まれるはず")
    }

    // MARK: - 漢字変換（azooKey）

    func testTanoshiiConvertsToKanji() {
        typeRomaji("tanoshii")
        XCTAssertEqual(client.markedText, "たのしい")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        guard case .show(let candidates, _, _) = action else {
            XCTFail("Space で .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("楽しい"), "「楽しい」が候補に含まれるはず: \(candidates)")
    }

    // MARK: - カタカナ変換・候補管理
    // See: docs/domain/glossary.md#fixedcount
    // See: docs/domain/glossary.md#historyend

    func testInitialRowSkipsFixedCandidatesWhenCandidatesExist() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, let initialRow) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertGreaterThan(candidates.count, 2, "azooKey が候補を返すはず")
        XCTAssertEqual(initialRow, 2, "initialRow はひらがな・カタカナの後（2）")
    }

    func testHiraganaInHistoryAppearsAsHistoryCandidate() {
        handler.db.record(input: "あい", output: "あい")
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show(let candidates, _, let initialRow) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates[0], "アイ", "カタカナが固定位置0番")
        XCTAssertEqual(candidates[1], "あい", "ひらがなが履歴エントリ（固定位置でなく）")
        XCTAssertEqual(initialRow, 1, "固定候補はカタカナの1件のみ")
    }

    func testKatakanaInHistoryAppearsAsHistoryCandidate() {
        handler.db.record(input: "あい", output: "アイ")
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show(let candidates, _, let initialRow) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates[0], "あい", "ひらがなが固定位置0番")
        XCTAssertEqual(candidates[1], "アイ", "カタカナが履歴エントリ（固定位置でなく）")
        XCTAssertEqual(initialRow, 1, "固定候補はひらがなの1件のみ")
    }

    func testReturnCommitsVisuallySelectedCandidateWithoutExplicitNav() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 2, selectedText: "愛")
        XCTAssertEqual(client.inserted, ["愛"], "Enter は視覚的に選択されている候補を確定する")
    }

    func testTypingDoesNotCommitWhenNotExplicitlySelected() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        type(chars: "k", base: "k", candidateVisible: true, selectedRow: 2, selectedText: "愛")
        XCTAssertTrue(client.inserted.isEmpty, "↑↓ なしで文字入力しても候補を確定しない")
        XCTAssertEqual(client.markedText, "あいk")
    }

    func testSpaceDuringCandidatesFallsBackToShowForSingleSegment() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 49, candidateVisible: true, selectedRow: 0)
        XCTAssertTrue(result.consumed)
        guard case .show = result.candidateAction else {
            XCTFail("単一セグメントのスペースは .show にフォールバックするはず: \(result.candidateAction)"); return
        }
    }

    func testSelectKatakanaCandidate() {
        typeRomaji("ai")
        press(keyCode: 36, candidateVisible: true, selectedText: "アイ", isExplicitlySelected: true)
        XCTAssertEqual(client.inserted, ["アイ"], "カタカナ候補を確定できるはず")
    }

    func testSpaceWithUnknownReadingShowsHiraganaAndKatakana() {
        type(chars: "u", base: "u")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        guard case .show(let candidates, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.contains("う"))
        XCTAssertTrue(candidates.contains("ウ"))
    }

    // MARK: - 候補ウィンドウ中のキーナビゲーション
    // See: docs/domain/states.md#候補選択中
    // See: docs/domain/scenarios.md#s-02-候補選択と右矢印確定

    func testDownArrowSelectsNext() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 125, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        guard case .selectNext = result.candidateAction else {
            XCTFail("↓ キーは .selectNext を返すはず"); return
        }
    }

    func testUpArrowSelectsPrev() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 126, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        guard case .selectPrev = result.candidateAction else {
            XCTFail("↑ キーは .selectPrev を返すはず"); return
        }
    }

    func testTabSelectsNext() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 48, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        guard case .selectNext = result.candidateAction else {
            XCTFail("Tab キーは .selectNext を返すはず"); return
        }
    }

    func testShiftTabSelectsPrev() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 48, modifiers: .shift, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        guard case .selectPrev = result.candidateAction else {
            XCTFail("Shift+Tab は .selectPrev を返すはず"); return
        }
    }

    func testDownArrowPassesThroughWithoutCandidates() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 125, candidateVisible: false)
        XCTAssertFalse(result.consumed, "候補なし時の ↓ はスルーするはず")
    }

    func testUpArrowPassesThroughWithoutCandidates() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 126, candidateVisible: false)
        XCTAssertFalse(result.consumed, "候補なし時の ↑ はスルーするはず")
    }

    func testRightArrowDuringCandidateCommitsHiragana() {
        // "か" を組成して候補ウィンドウに漢字候補「花」が選択されている状態
        typeRomaji("ka")
        let result = press(keyCode: 124, candidateVisible: true, selectedText: "花")
        XCTAssertTrue(result.consumed)
        // 漢字ではなくひらがなが確定される
        XCTAssertEqual(client.inserted, ["か"])
        XCTAssertTrue(handler.state.composingText.isEmpty, "確定後は組成バッファが空になるはず")
    }

    func testRightArrowDuringCandidateIgnoresSelectedCandidate() {
        // 候補が明示的に選択されていても右矢印はひらがなを確定する
        typeRomaji("nihon")
        let result = press(keyCode: 124, candidateVisible: true,
                           selectedRow: 2, selectedText: "日本", isExplicitlySelected: true)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["にほん"])
    }

    // MARK: - 候補ウィンドウ中のバックスペース・Escape

    func testBackspaceDuringCandidateDisplayDismissesWhenSingleCharRemains() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let result = press(keyCode: 51, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "あ")
        guard case .dismiss = result.candidateAction else {
            XCTFail("1文字になったら .dismiss するはず: \(result.candidateAction)"); return
        }
    }

    func testBackspaceDuringCandidateDisplayRefreshesWhenMultipleCharsRemain() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        type(chars: "u", base: "u")
        let result = press(keyCode: 51, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "あい")
        guard case .show = result.candidateAction else {
            XCTFail("2文字以上残るなら .show を返すはず: \(result.candidateAction)"); return
        }
    }

    func testEscapeDuringCandidateDisplayClearsComposition() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let result = press(keyCode: 53, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "")
        XCTAssertTrue(client.inserted.isEmpty)
        guard case .dismiss = result.candidateAction else {
            XCTFail("候補表示中の Escape は .dismiss を返すはず"); return
        }
    }

    // MARK: - autoShow: 候補ゼロ時は表示しない
    // See: docs/domain/glossary.md#autoshow

    func testAutoShowDismissesWhenNoCandidates() {
        // ASCII 組成（履歴ゼロ・辞書スキップ）で文字入力 → buildCandidateList(autoShow:true) は .dismiss
        let (consumed, action) = type(chars: "X", base: "x", modifiers: .shift)
        XCTAssertTrue(consumed)
        guard case .dismiss = action else {
            XCTFail("履歴・辞書・予測候補がゼロなら autoShow は .dismiss を返すはず: \(action)"); return
        }
    }

    // MARK: - historyEnd 境界: Shift+Delete の削除可否
    // See: docs/domain/glossary.md#historyend
    // See: docs/domain/scenarios.md#s-06-shiftdelete-で履歴削除

    func testShiftDeleteInsideHistoryEndDeletesCandidate() {
        // selectedRow < historyEnd → .deleteSelected を返す
        typeRomaji("ka")
        let ctx = CandidateContext(isVisible: true, selectedRow: 1, selectedText: nil,
                                   isExplicitlySelected: true, historyEnd: 2)
        let (_, action) = handler.handle(keyCode: KeyCode.backspace, characters: nil, baseCharacters: nil,
                                          modifiers: .shift, candidate: ctx, client: client)
        guard case .deleteSelected = action else {
            XCTFail("historyEnd 未満の Shift+Delete は .deleteSelected を返すはず: \(action)"); return
        }
    }

    func testShiftDeleteOutsideHistoryEndDoesNothing() {
        // selectedRow >= historyEnd → .none を返す（AzooKey 専用候補は削除不可）
        typeRomaji("ka")
        let ctx = CandidateContext(isVisible: true, selectedRow: 5, selectedText: nil,
                                   isExplicitlySelected: true, historyEnd: 2)
        let (_, action) = handler.handle(keyCode: KeyCode.backspace, characters: nil, baseCharacters: nil,
                                          modifiers: .shift, candidate: ctx, client: client)
        guard case .none = action else {
            XCTFail("historyEnd 以降の Shift+Delete は .none を返すはず: \(action)"); return
        }
        XCTAssertTrue(client.inserted.isEmpty, "削除不可なので確定テキストは挿入されないはず")
    }
}
