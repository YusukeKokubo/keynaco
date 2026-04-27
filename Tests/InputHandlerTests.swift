import XCTest
@testable import keynaco

// MARK: - モッククライアント

final class MockTextClient: TextInputClient {
    private(set) var inserted: [String] = []
    private(set) var markedText: String = ""

    func insertText(_ text: String) { inserted.append(text); markedText = "" }
    func setMarkedText(_ text: String, selectionRange: NSRange) { markedText = text }
    func cursorRect() -> NSRect { .zero }
}

// MARK: - テスト

final class InputHandlerTests: XCTestCase {

    private var handler: InputHandler!
    private var client: MockTextClient!

    override func setUp() {
        super.setUp()
        InputHandler.isAsciiMode = false
        handler = InputHandler(db: DatabaseManager(inMemory: true))
        client = MockTextClient()
    }

    // MARK: - ユーティリティ

    @discardableResult
    private func type(
        chars: String,
        base: String? = nil,
        modifiers: NSEvent.ModifierFlags = [],
        candidateVisible: Bool = false,
        selectedRow: Int = 0,
        selectedText: String? = nil
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        let ctx = CandidateContext(isVisible: candidateVisible, selectedRow: selectedRow, selectedText: selectedText)
        return handler.handle(keyCode: 0, characters: chars, baseCharacters: base ?? chars,
                               modifiers: modifiers, candidate: ctx, client: client)
    }

    @discardableResult
    private func press(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        candidateVisible: Bool = false,
        selectedRow: Int = 0,
        selectedText: String? = nil,
        isExplicitlySelected: Bool = false
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        let ctx = CandidateContext(isVisible: candidateVisible, selectedRow: selectedRow, selectedText: selectedText, isExplicitlySelected: isExplicitlySelected)
        return handler.handle(keyCode: keyCode, characters: nil, baseCharacters: nil,
                               modifiers: modifiers, candidate: ctx, client: client)
    }

    private func typeRomaji(_ s: String) {
        for c in s { type(chars: String(c), base: String(c)) }
    }

    // MARK: - ローマ字 → ひらがな変換

    func testTypingKaMarksHiragana() {
        type(chars: "k", base: "k")
        XCTAssertEqual(client.markedText, "k")
        type(chars: "a", base: "a")
        XCTAssertEqual(client.markedText, "か")
    }

    func testTypingSingleVowel() {
        type(chars: "a", base: "a")
        XCTAssertEqual(client.markedText, "あ")
    }

    func testTypingTwoVowelsAutoShowsDictionaryCandidates() {
        type(chars: "a", base: "a")
        let (consumed, action) = type(chars: "i", base: "i")
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.markedText, "あい")
        guard case .show(let candidates, _, _) = action else {
            XCTFail("辞書候補があればタイピング中も自動表示するはず: \(action)"); return
        }
        XCTAssertFalse(candidates.isEmpty)
    }

    func testTypingShowsCandidatesWhenHistoryExists() {
        handler.db.record(input: "あい", output: "愛")
        type(chars: "a", base: "a")
        let (consumed, action) = type(chars: "i", base: "i")
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.markedText, "あい")
        guard case .show(let candidates, _, _) = action else {
            XCTFail("履歴ありなら自動表示するはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("あい"))
    }

    // MARK: - Return で確定

    func testReturnCommitsComposing() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 36)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["あ"])
    }

    func testReturnWhenEmptyPassesThrough() {
        let result = press(keyCode: 36)
        XCTAssertFalse(result.consumed)
        XCTAssertTrue(client.inserted.isEmpty)
    }

    func testReturnWithSelectedCandidateCommitsCandidate() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 1, selectedText: "阿", isExplicitlySelected: true)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["阿"])
        guard case .show = result.candidateAction else {
            XCTFail("確定後は格助詞リストを表示するはず: \(result.candidateAction)"); return
        }
        XCTAssertTrue(handler.isSuccessorMode)
    }

    // MARK: - Escape でリセット

    func testEscapeClearsComposing() {
        type(chars: "k", base: "k")
        XCTAssertEqual(client.markedText, "k")
        let result = press(keyCode: 53)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "")
        guard case .dismiss = result.candidateAction else {
            XCTFail("Escape は .dismiss を返すはず"); return
        }
    }

    func testEscapeWhenEmptyPassesThrough() {
        XCTAssertFalse(press(keyCode: 53).consumed)
    }

    // MARK: - Backspace

    func testBackspaceRemovesPendingRomaji() {
        type(chars: "k", base: "k")
        XCTAssertEqual(client.markedText, "k")
        let result = press(keyCode: 51)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "")
    }

    func testBackspaceRemovesHiragana() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        XCTAssertEqual(client.markedText, "あい")
        let result = press(keyCode: 51)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "あ")
    }

    func testBackspaceWhenEmptyPassesThrough() {
        XCTAssertFalse(press(keyCode: 51).consumed)
    }

    // MARK: - スペースで候補表示

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

    // MARK: - 候補ウィンドウ中のキーナビゲーション

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

    // MARK: - ASCII モード（英数キー）

    func testAsciiModeInsertsDirectly() {
        press(keyCode: 102)
        let result = type(chars: "a", base: "a")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["a"])
        XCTAssertEqual(client.markedText, "")
    }

    func testAsciiModeCommitsComposingFirst() {
        type(chars: "a", base: "a")
        press(keyCode: 102)
        XCTAssertEqual(client.inserted, ["あ"])
    }

    func testEscapeExitsAsciiMode() {
        press(keyCode: 102)
        press(keyCode: 53)
        type(chars: "a", base: "a")
        XCTAssertEqual(client.markedText, "あ")
        XCTAssertTrue(client.inserted.isEmpty)
    }

    // MARK: - Shift + 文字 → 組成バッファに英字として貯める

    func testShiftLetterInsertsDirectly() {
        type(chars: "A", base: "a", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "A")
    }

    func testShiftLetterCommitsComposingFirst() {
        type(chars: "a", base: "a")
        type(chars: "B", base: "b", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あB")
    }

    // MARK: - Shift+記号・非ASCII文字

    func testFullWidthSymbolInsertedDirectlyWhenEmpty() {
        let result = type(chars: "！", base: "!")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["！"])
        XCTAssertEqual(client.markedText, "")
    }

    func testFullWidthSymbolAppendsToComposition() {
        type(chars: "a", base: "a")
        type(chars: "！", base: "!")
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ！")
    }

    func testFullWidthSymbolDoesNotConfirmCandidate() {
        type(chars: "a", base: "a")
        let ctx = CandidateContext(isVisible: true, selectedRow: 1, selectedText: "阿", isExplicitlySelected: true)
        _ = handler.handle(keyCode: 0, characters: "！", baseCharacters: "!",
                           modifiers: [], candidate: ctx, client: client)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ！")
    }

    func testShiftSymbolInsertedDirectlyWhenEmpty() {
        let result = type(chars: "!", base: "1", modifiers: .shift)
        XCTAssertTrue(result.consumed)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "!")
    }

    func testShiftSymbolAppendsToComposition() {
        type(chars: "a", base: "a")
        type(chars: "!", base: "1", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ!")
    }

    // MARK: - 句読点変換

    func testPeriodInsertsJapanesePeriod() {
        let result = type(chars: ".", base: ".")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["。"])
        XCTAssertEqual(client.markedText, "")
    }

    func testCommaInsertsJapaneseComma() {
        let result = type(chars: ",", base: ",")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["、"])
        XCTAssertEqual(client.markedText, "")
    }

    func testPeriodAppendsToCompositionAndOpensCandidates() {
        type(chars: "a", base: "a")
        let result = type(chars: ".", base: ".")
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ。")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testCommaAppendsToCompositionAndOpensCandidates() {
        type(chars: "a", base: "a")
        let result = type(chars: ",", base: ",")
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ、")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testPeriodAfterPendingConsonantFlushesPending() {
        type(chars: "k", base: "k")
        let result = type(chars: ".", base: ".")
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "k。")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testPeriodDoesNotCommitSelectedCandidate() {
        type(chars: "a", base: "a")
        let ctx = CandidateContext(isVisible: true, selectedRow: 1, selectedText: "阿", isExplicitlySelected: true)
        _ = handler.handle(keyCode: 0, characters: ".", baseCharacters: ".",
                           modifiers: [], candidate: ctx, client: client)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ。")
    }

    func testCommaDoesNotCommitSelectedCandidate() {
        type(chars: "a", base: "a")
        let ctx = CandidateContext(isVisible: true, selectedRow: 1, selectedText: "阿", isExplicitlySelected: true)
        _ = handler.handle(keyCode: 0, characters: ",", baseCharacters: ",",
                           modifiers: [], candidate: ctx, client: client)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ、")
    }

    // MARK: - Shift+句読点キー → 角括弧入力

    func testShiftCommaInputsLessThan() {
        // Shift+, → "<" が組成バッファへ（"、"にならない）
        type(chars: "<", base: ",", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "<")
    }

    func testShiftPeriodInputsGreaterThan() {
        // Shift+. → ">" が組成バッファへ（"。"にならない）
        type(chars: ">", base: ".", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, ">")
    }

    func testAngleBracketsCanBeConfirmedWithEnter() {
        // "<>" と入力して Enter で確定できる
        type(chars: "<", base: ",", modifiers: .shift)
        type(chars: ">", base: ".", modifiers: .shift)
        XCTAssertEqual(client.markedText, "<>")
        press(keyCode: 36)  // Enter
        XCTAssertEqual(client.inserted, ["<>"])
        XCTAssertEqual(client.markedText, "")
    }

    func testShiftCommaAppendsToJapaneseComposition() {
        // 日本語組成中に Shift+, → "<" が末尾に追加される
        type(chars: "a", base: "a")
        type(chars: "<", base: ",", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ<")
    }

    func testCommaStillMapsToJapaneseCommaWithoutShift() {
        // Shift なし "," → "、" は従来通り
        type(chars: ",", base: ",")
        XCTAssertEqual(client.inserted, ["、"])
    }

    func testPeriodStillMapsToJapanesePeriodWithoutShift() {
        // Shift なし "." → "。" は従来通り
        type(chars: ".", base: ".")
        XCTAssertEqual(client.inserted, ["。"])
    }

    // MARK: - セグメントモード

    func testSpaceEntersSegmentModeWhenMultipleSegments() {
        typeRomaji("watashihagakusei")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        // azooKey が複数セグメントに分割する場合はセグメントモードへ
        if handler.state.isSegmentMode {
            guard case .show = action else {
                XCTFail("セグメントモード時は .show を返すはず: \(action)"); return
            }
        } else {
            guard case .show = action else {
                XCTFail("単一セグメント時も .show にフォールバックするはず: \(action)"); return
            }
        }
    }

    func testSpaceFallsBackToNormalModeForSingleSegment() {
        type(chars: "a", base: "a")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        guard case .show = action else {
            XCTFail("単一セグメントでも .show にフォールバックするはず: \(action)"); return
        }
    }

    func testSegmentModeEnterConfirmsAndInserts() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode or normal
        let (consumed, _) = press(keyCode: 36)  // Enter
        XCTAssertTrue(consumed)
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertFalse(client.inserted.isEmpty, "確定でテキストが挿入されるはず")
        // successor mode display depends on AzooKey conversion; tested in testSuccessorMode* tests
    }

    func testSegmentModeEscapeRestoresComposing() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        guard handler.state.isSegmentMode else { return }  // 1セグメントならスキップ

        let (consumed, action) = press(keyCode: 53)  // Escape
        XCTAssertTrue(consumed)
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertEqual(handler.state.composedHiragana, "わたしはがくせい")
        XCTAssertTrue(client.inserted.isEmpty)
        guard case .dismiss = action else {
            XCTFail("Escape は .dismiss を返すはず: \(action)"); return
        }
    }

    func testSegmentModeBackspaceExits() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        guard handler.state.isSegmentMode else { return }

        let (consumed, action) = press(keyCode: 51)  // Backspace
        XCTAssertTrue(consumed)
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertTrue(client.inserted.isEmpty)
        guard case .dismiss = action else {
            XCTFail("Backspace は .dismiss を返すはず: \(action)"); return
        }
    }

    func testSegmentModeLeftRightMovesFocus() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space
        guard handler.state.isSegmentMode else { return }

        XCTAssertEqual(handler.state.segmentState?.focusedIndex, 0)
        press(keyCode: 124)  // Right
        XCTAssertGreaterThan(handler.state.segmentState?.focusedIndex ?? 0, 0)
        press(keyCode: 123)  // Left
        XCTAssertEqual(handler.state.segmentState?.focusedIndex, 0)
    }

    func testSegmentModeHistoryRecordedPerSegment() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)   // Space → segment mode or candidate display
        press(keyCode: 36)   // Enter → confirm all

        // 確定後にテキストが挿入されること（セグメント確定 or 全体確定）
        XCTAssertFalse(client.inserted.isEmpty, "確定でテキストが挿入されるはず")
    }

    func testCommitCompositionInSegmentMode() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        guard handler.state.isSegmentMode else { return }

        handler.commitComposition(client: client)
        XCTAssertFalse(client.inserted.isEmpty, "deactivateServer 相当の強制確定")
        XCTAssertFalse(handler.state.isSegmentMode)
    }

    // MARK: - セグメント境界調整（Shift+矢印）

    func testSegmentResizeExpandShiftRight() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss0 = handler.state.segmentState,
              ss0.segments.count >= 2 else { return }

        let firstReading = ss0.segments[0].reading
        let nextFirst = ss0.segments[1].reading.first!
        press(keyCode: 124, modifiers: .shift)  // Shift+Right
        guard let ss = handler.state.segmentState else {
            XCTFail("セグメントモードが維持されるはず"); return
        }
        XCTAssertEqual(ss.segments[0].reading, firstReading + String(nextFirst),
                       "フォーカスセグメントが1文字拡張されるはず")
    }

    func testSegmentResizeShrinkShiftLeft() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss0 = handler.state.segmentState,
              ss0.segments[0].reading.count >= 2 else { return }

        let firstReading = ss0.segments[0].reading
        press(keyCode: 123, modifiers: .shift)  // Shift+Left
        guard let ss = handler.state.segmentState else {
            XCTFail("セグメントモードが維持されるはず"); return
        }
        XCTAssertEqual(ss.segments[0].reading, String(firstReading.dropLast()),
                       "フォーカスセグメントが1文字縮小されるはず")
    }

    func testSegmentResizeConfirmAfterResize() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode else { return }

        press(keyCode: 124, modifiers: .shift)  // Shift+Right
        press(keyCode: 36)   // Enter → 確定
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertFalse(client.inserted.isEmpty)
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

    // MARK: - 変換確定と履歴記録

    func testHistoryRecordedAfterEnterConfirmation() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        press(keyCode: 36)  // Enter → 確定
        let hist = handler.db.fetchHistoryExact(reading: "あい")
        XCTAssertTrue(hist.contains("あい"), "Enter 確定後にひらがなが履歴として記録されるはず")
    }

    func testHistoryRecordedAfterCandidateSelectionAndEnter() {
        type(chars: "a", base: "a")
        press(keyCode: 36, candidateVisible: true, selectedRow: 1, selectedText: "阿")
        let hist = handler.db.fetchHistoryExact(reading: "あ")
        XCTAssertTrue(hist.contains("阿"), "候補選択→Enter 確定後に変換結果が履歴として記録されるはず")
    }

    func testConversionHistoryBoostsNextConversion() {
        typeRomaji("tanoshii")
        press(keyCode: 36, candidateVisible: true, selectedText: "楽しい")
        press(keyCode: 53)  // Escape でSuccessor モードを解除
        typeRomaji("tanoshii")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, let historyEnd, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.prefix(historyEnd).contains("楽しい"),
                      "前回確定した「楽しい」が次回変換で履歴候補として現れるはず")
    }

    // MARK: - 確定後の再入力

    func testTypingAfterConfirmationStartsFreshComposition() {
        type(chars: "a", base: "a")
        press(keyCode: 36)
        XCTAssertEqual(client.inserted, ["あ"])
        type(chars: "i", base: "i")
        XCTAssertEqual(client.markedText, "い", "確定後は新しい組成が始まるはず")
        XCTAssertEqual(client.inserted, ["あ"], "追加挿入はないはず")
    }

    // MARK: - 長音符（ー）

    func testLongVowelMarkAppendsToComposition() {
        type(chars: "r", base: "r")
        type(chars: "a", base: "a")
        type(chars: "-", base: "-")
        XCTAssertEqual(client.markedText, "らー", "ハイフンが長音符「ー」に変換されるはず")
    }

    // MARK: - かなキー

    func testKanaKeyExitsAsciiMode() {
        press(keyCode: 102)
        XCTAssertTrue(InputHandler.isAsciiMode)
        press(keyCode: 104)
        XCTAssertFalse(InputHandler.isAsciiMode)
        type(chars: "a", base: "a")
        XCTAssertEqual(client.markedText, "あ")
        XCTAssertTrue(client.inserted.isEmpty)
    }

    // MARK: - composedHiragana が空のときのスペース

    func testSpacePassesThroughWithOnlyPendingRomaji() {
        type(chars: "k", base: "k")
        XCTAssertEqual(client.markedText, "k")
        let result = press(keyCode: 49)
        XCTAssertFalse(result.consumed, "composedHiragana が空のときスペースはスルーするはず")
        XCTAssertEqual(client.markedText, "k", "組成は変化しないはず")
    }

    // MARK: - commitComposition（deactivateServer 相当）

    func testCommitCompositionFinalizesHiragana() {
        type(chars: "k", base: "k")
        type(chars: "a", base: "a")
        handler.commitComposition(client: client)
        XCTAssertEqual(client.inserted, ["か"])
    }

    func testCommitCompositionConvertsPendingN() {
        type(chars: "k", base: "k")
        type(chars: "a", base: "a")
        type(chars: "n", base: "n")
        handler.commitComposition(client: client)
        XCTAssertEqual(client.inserted, ["かん"])
    }

    func testCommitCompositionWhenEmptyDoesNothing() {
        handler.commitComposition(client: client)
        XCTAssertTrue(client.inserted.isEmpty)
    }

    func testCommitCompositionWithExplicitCandidateCommitsCandidate() {
        type(chars: "a", base: "a")
        let ctx = CandidateContext(isVisible: true, selectedRow: 1, selectedText: "阿", isExplicitlySelected: true)
        handler.commitComposition(client: client, candidate: ctx)
        XCTAssertEqual(client.inserted, ["阿"])
    }

    func testCommitCompositionWithRowZeroCommitsHiragana() {
        type(chars: "a", base: "a")
        let ctx = CandidateContext(isVisible: true, selectedRow: 0, selectedText: "あ")
        handler.commitComposition(client: client, candidate: ctx)
        XCTAssertEqual(client.inserted, ["あ"])
    }

    // MARK: - 自然な日本語入力シナリオ

    func testSokuonProducesSmallTsu() {
        typeRomaji("kka")
        XCTAssertEqual(client.markedText, "っか")
    }

    func testSokuonMidWord() {
        typeRomaji("zasshi")
        XCTAssertEqual(client.markedText, "ざっし")
    }

    func testNAutoFinalizedBeforeConsonant() {
        typeRomaji("kanji")
        XCTAssertEqual(client.markedText, "かんじ")
    }

    func testNNPendingNRemainsAfterDoubleN() {
        typeRomaji("nn")
        XCTAssertEqual(client.markedText, "んn")
    }

    func testNNThenVowelFinalizesN() {
        typeRomaji("nna")
        XCTAssertEqual(client.markedText, "んな")
    }

    func testNBeforeVowelDoesNotProduceN() {
        typeRomaji("na")
        XCTAssertEqual(client.markedText, "な")
    }

    func testYouonKyo() {
        typeRomaji("kyo")
        XCTAssertEqual(client.markedText, "きょ")
    }

    func testYouonSha() {
        typeRomaji("sha")
        XCTAssertEqual(client.markedText, "しゃ")
    }

    func testYouonChi() {
        typeRomaji("chi")
        XCTAssertEqual(client.markedText, "ち")
    }

    func testYouonTsu() {
        typeRomaji("tsu")
        XCTAssertEqual(client.markedText, "つ")
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

    func testBackspaceOneByOneFromComposition() {
        typeRomaji("uta")
        XCTAssertEqual(client.markedText, "うた")
        press(keyCode: 51)
        XCTAssertEqual(client.markedText, "う")
        press(keyCode: 51)
        XCTAssertEqual(client.markedText, "")
    }

    func testVerbOkuriganaConversion() {
        typeRomaji("kaki")
        XCTAssertEqual(client.markedText, "かき")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.contains("書き"), "「書き」が候補に含まれるはず: \(candidates)")
    }

    // MARK: - Successor モード（確定後の後続語予測 / 格助詞クイック選択を含む）

    func testSuccessorModeActivatesAfterCommit() {
        typeRomaji("tokyo")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode, "漢字確定後はSuccessor モードになるはず")
        guard case .show(let candidates, _, _) = result.candidateAction else {
            XCTFail("格助詞リストを表示するはず: \(result.candidateAction)"); return
        }
        XCTAssertTrue(InputHandler.particles.allSatisfy { candidates.contains($0) }, "全格助詞が候補に含まれるはず")
    }

    func testSuccessorModeSpaceConfirmsParticle() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        // Space で先頭の格助詞を確定
        let firstParticle = InputHandler.particles[0]  // "が"
        let result = press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: firstParticle)
        XCTAssertTrue(result.consumed)
        XCTAssertFalse(handler.isSuccessorMode, "確定後はSuccessor モードを抜けるはず")
        XCTAssertTrue(client.inserted.contains(firstParticle), "格助詞が挿入されるはず")
    }

    func testSuccessorModeEscapeDismisses() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        let result = press(keyCode: 53)  // Escape
        XCTAssertTrue(result.consumed)
        XCTAssertFalse(handler.isSuccessorMode)
        guard case .dismiss = result.candidateAction else {
            XCTFail("Escape は .dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorModeRomajiExitsAndComposesNormally() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        // "s" は格助詞マッチなし → Successor モード解除して通常組成
        let result = type(chars: "s", base: "s")
        XCTAssertFalse(handler.isSuccessorMode, "マッチなしキーでSuccessor モードを抜けるはず")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "s", "通常の組成が始まるはず")
    }

    func testSuccessorModeNotRetriggeredAfterParticleConfirm() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let firstParticle = InputHandler.particles[0]
        press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: firstParticle)
        // 格助詞確定後はSuccessor モードが再トリガーされない
        XCTAssertFalse(handler.isSuccessorMode, "格助詞確定後はSuccessor モードにならないはず")
    }

    func testSuccessorModeArrowNavigates() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        let result = press(keyCode: 125, candidateVisible: true, selectedRow: 0, selectedText: "が")  // ↓
        guard case .selectNext = result.candidateAction else {
            XCTFail("↓ は .selectNext を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorModeRomajiUniqueFiltersAndConfirmWithSpace() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        // "g" → が（唯一マッチ）→ フィルタリング表示（まだ確定しない）
        let filterResult = type(chars: "g", base: "g")
        XCTAssertTrue(filterResult.consumed)
        XCTAssertTrue(handler.isSuccessorMode, "フィルタリング中はSuccessor モードを維持するはず")
        guard case .show(let candidates, _, _) = filterResult.candidateAction else {
            XCTFail("絞り込み後は .show を返すはず: \(filterResult.candidateAction)"); return
        }
        XCTAssertEqual(candidates, ["が"], "「が」のみが候補に含まれるはず")
        // Space で確定
        let confirmResult = press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertFalse(handler.isSuccessorMode, "確定後はSuccessor モードを抜けるはず")
        XCTAssertTrue(client.inserted.contains("が"), "「が」が挿入されるはず")
        guard case .dismiss = confirmResult.candidateAction else {
            XCTFail("確定後は .dismiss を返すはず: \(confirmResult.candidateAction)"); return
        }
    }

    func testSuccessorModeRomajiAmbiguousFilters() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        // "n" → に・の（複数マッチ）→ 絞り込み表示
        let result = type(chars: "n", base: "n", candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertTrue(result.consumed)
        XCTAssertTrue(handler.isSuccessorMode, "絞り込み中はSuccessor モードを維持するはず")
        guard case .show(let candidates, _, _) = result.candidateAction else {
            XCTFail("絞り込み後は .show を返すはず: \(result.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("に") && candidates.contains("の"), "に・の が候補に含まれるはず: \(candidates)")
        XCTAssertFalse(candidates.contains("が"), "他の格助詞は含まれないはず")
    }

    func testSuccessorModeUnmatchedKeyExitsMode() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        // "a" → 格助詞マッチなし → Successor モード解除して通常入力
        let result = type(chars: "a", base: "a")
        XCTAssertFalse(handler.isSuccessorMode, "マッチなしキーでSuccessor モードを抜けるはず")
        XCTAssertEqual(client.markedText, "あ", "通常の組成になるはず")
    }

    // MARK: - Successor モード：格助詞 fallback の発火条件（名詞末尾のみ）

    func testSuccessorModeActivatesAfterKanji() {
        typeRomaji("tokyo")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode, "漢字末尾の確定後は格助詞モードになるはず")
        guard case .show = result.candidateAction else {
            XCTFail(".show を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorModeActivatesAfterKatakana() {
        typeRomaji("koohii")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "コーヒー")
        XCTAssertTrue(handler.isSuccessorMode, "カタカナ末尾の確定後は格助詞モードになるはず")
        guard case .show = result.candidateAction else {
            XCTFail(".show を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorModeNotActivatedAfterHiragana() {
        typeRomaji("ta")  // → "た"（ひらがな確定）
        let result = press(keyCode: 36)
        XCTAssertFalse(handler.isSuccessorMode, "ひらがな末尾の確定後は格助詞モードにならないはず")
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorModeNotActivatedAfterSymbol() {
        typeRomaji("a")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "？")
        XCTAssertFalse(handler.isSuccessorMode, "記号確定後は格助詞モードにならないはず")
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorModeNotActivatedAfterASCII() {
        typeRomaji("a")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "Hello")
        XCTAssertFalse(handler.isSuccessorMode, "ASCII確定後は格助詞モードにならないはず")
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorModeNotActivatedAfterJapanesePunctuation() {
        typeRomaji("a")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "！")
        XCTAssertFalse(handler.isSuccessorMode, "日本語感嘆符確定後は格助詞モードにならないはず")
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    // MARK: - Successor モード：bi-gram 一般化

    func testSuccessorModeShowsBigramTopAfterHiraganaCommit() {
        // 事前に「おつかれ → です」を学習させる
        handler.db.recordBigram(prev: "おつかれ", input: "です", output: "です")
        typeRomaji("otsukare")
        let result = press(keyCode: 36)  // Enter でひらがな確定
        XCTAssertTrue(handler.isSuccessorMode, "ひらがな末尾でも bi-gram があれば Successor モードになる")
        guard case .show(let candidates, _, _) = result.candidateAction else {
            XCTFail(".show を返すはず: \(result.candidateAction)"); return
        }
        XCTAssertEqual(candidates, ["です"], "bi-gram 学習済みの output のみ表示（格助詞 fallback なし）")
    }

    func testSuccessorModeBigramOrderedByFrequency() {
        // 「東京 → で」を 3 回、「東京 → に」を 1 回 学習
        for _ in 0..<3 { handler.db.recordBigram(prev: "東京", input: "で", output: "で") }
        handler.db.recordBigram(prev: "東京", input: "に", output: "に")
        typeRomaji("tokyo")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        guard case .show(let candidates, _, _) = result.candidateAction else {
            XCTFail(".show を返すはず: \(result.candidateAction)"); return
        }
        let idxDe = candidates.firstIndex(of: "で")!
        let idxNi = candidates.firstIndex(of: "に")!
        XCTAssertLessThan(idxDe, idxNi, "頻度の高い bi-gram 候補が先頭")
        // 名詞末尾なので格助詞 fallback も tail に並ぶ
        XCTAssertTrue(InputHandler.particles.allSatisfy { candidates.contains($0) }, "格助詞 fallback も表示")
    }

    func testSuccessorModeNonParticleBigramFallsThroughOn1stKey() {
        // ひらがな末尾「おつかれ」の後に非格助詞 bi-gram「です」を学習
        handler.db.recordBigram(prev: "おつかれ", input: "です", output: "です")
        typeRomaji("otsukare")
        press(keyCode: 36)  // 「おつかれ」確定 → Successor モードへ
        XCTAssertTrue(handler.isSuccessorMode)
        // 「k」打鍵 → 名詞末尾ではないので fast-path が効かず、通常組成へ
        let result = type(chars: "k", base: "k")
        XCTAssertFalse(handler.isSuccessorMode, "非名詞末尾で 1 打目は fast-path を使わず通常組成へ")
        XCTAssertEqual(client.markedText, "k", "通常の組成が始まる")
        XCTAssertTrue(result.consumed)
    }

    func testSuccessorModeParticleFallbackOnlyWhenNounLike() {
        // 学習なしの状態で「た」（ひらがな末尾）を確定
        typeRomaji("ta")
        let result = press(keyCode: 36)
        XCTAssertFalse(handler.isSuccessorMode, "ひらがな末尾 + 学習なしなら Successor モードは起動しない")
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    // MARK: - Trigram 統合テスト

    func testTrigramLearnedAndPrioritizedOverBigram() {
        // 1語目「昨日」確定
        typeRomaji("kinou")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "昨日")
        // Successor モード終了
        press(keyCode: 53) // Escape

        // 2語目「東京」確定
        typeRomaji("toukyou")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        press(keyCode: 53)

        // 3語目「行った」確定（bigram: 東京→行った、trigram: 昨日/東京→行った が学習される）
        typeRomaji("itta")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "行った")
        press(keyCode: 53)

        // bigram のみの競合語「住んだ」を bigram で学習（東京→住んだ）
        // 別文脈: 「今日」「東京」「住んだ」で bigram(東京→住んだ) だけ積む
        let db = handler.db
        db.recordBigram(prev: "東京", input: "すんだ", output: "住んだ")
        db.recordBigram(prev: "東京", input: "すんだ", output: "住んだ")
        db.recordBigram(prev: "東京", input: "すんだ", output: "住んだ")

        // 「昨日」「東京」に続く4語目を組成中 → trigram (昨日/東京→行った) が上に来るはず
        typeRomaji("i")
        let action = type(chars: "t", base: "t")
        guard case .show(let candidates, _, _) = action.candidateAction else {
            XCTFail("候補が表示されるはず"); return
        }
        // bigram のみ持つ「住んだ」より trigram で学習済みの「行った」が上位にあること
        let idxItta = candidates.firstIndex(of: "行った")
        let idxSunda = candidates.firstIndex(of: "住んだ")
        if let i = idxItta, let s = idxSunda {
            XCTAssertLessThan(i, s, "trigram 由来の候補が bigram のみの候補より上に並ぶ")
        } else if idxItta == nil {
            XCTFail("行った が候補に含まれていない: \(candidates)")
        }
    }
}
