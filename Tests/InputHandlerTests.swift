import XCTest
@testable import ykey

// MARK: - モッククライアント

final class MockTextClient: TextInputClient {
    private(set) var inserted: [String] = []
    private(set) var markedText: String = ""

    func insertText(_ text: String) { inserted.append(text) }
    func setMarkedText(_ text: String, selectionRange: NSRange) { markedText = text }
    func cursorRect() -> NSRect { .zero }
}

// MARK: - テスト

final class InputHandlerTests: XCTestCase {

    private var handler: InputHandler!
    private var client: MockTextClient!

    override func setUp() {
        super.setUp()
        handler = InputHandler(db: DatabaseManager(inMemory: true))
        client = MockTextClient()
    }

    // MARK: - ユーティリティ

    /// 文字キーを入力する（keyCode は使わない）
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

    /// keyCode で特殊キーを押す（Return=36, Escape=53, Space=49, BS=51, 英数=102, かな=104）
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

    func testTypingTwoVowelsShowsCandidates() {
        type(chars: "a", base: "a")
        let (consumed, action) = type(chars: "i", base: "i")
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.markedText, "あい")
        guard case .show(let candidates, _, _) = action else {
            XCTFail("2文字以上で .show を返すはず: \(action)"); return
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
        handler.db.insertDict(reading: "あ", candidate: "阿", priority: 0)
        type(chars: "a", base: "a")
        // isExplicitlySelected: true = ↑↓ で明示的に選んだ状態
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 1, selectedText: "阿", isExplicitlySelected: true)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["阿"])
        guard case .dismiss = result.candidateAction else {
            XCTFail("確定後は .dismiss を返すはず"); return
        }
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

    func testKatakanaAppearsAtIndexOne() {
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
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

    // MARK: - 漢字変換（辞書引き）

    func testTanoshiiConvertsToKanji() {
        handler.db.insertDict(reading: "たのしい", candidate: "楽しい", priority: 0)
        typeRomaji("tanoshii")
        XCTAssertEqual(client.markedText, "たのしい")
        let (consumed, action) = press(keyCode: 49)  // Space
        XCTAssertTrue(consumed)
        guard case .show(let candidates, _, _) = action else {
            XCTFail("Space で .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("楽しい"), "「楽しい」が候補に含まれるはず: \(candidates)")
    }

    // MARK: - カタカナ変換・候補管理

    func testInitialRowSkipsFixedCandidatesWhenDictExists() {
        handler.db.insertDict(reading: "あい", candidate: "愛", priority: 0)
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show(_, _, let initialRow) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(initialRow, 2, "辞書候補がある場合 initialRow はひらがな・カタカナの後（2）")
    }

    func testHiraganaInHistoryAppearsAsHistoryCandidate() {
        handler.db.record(input: "あい", output: "あい")
        handler.db.insertDict(reading: "あい", candidate: "愛", priority: 0)
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show(let candidates, _, let initialRow) = action else {
            XCTFail(".show を返すはず"); return
        }
        // ひらがなが履歴にある → 固定位置に追加せず履歴エントリとして可視範囲に表示
        // candidates = [アイ(固定), あい(履歴), 愛(辞書)]
        XCTAssertEqual(candidates[0], "アイ", "カタカナが固定位置0番")
        XCTAssertEqual(candidates[1], "あい", "ひらがなが履歴エントリ（固定位置でなく）")
        XCTAssertEqual(initialRow, 1, "固定候補はカタカナの1件のみ")
    }

    func testKatakanaInHistoryAppearsAsHistoryCandidate() {
        handler.db.record(input: "あい", output: "アイ")
        handler.db.insertDict(reading: "あい", candidate: "愛", priority: 0)
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show(let candidates, _, let initialRow) = action else {
            XCTFail(".show を返すはず"); return
        }
        // カタカナが履歴にある → 固定位置に追加せず履歴エントリとして可視範囲に表示
        // candidates = [あい(固定), アイ(履歴), 愛(辞書)]
        XCTAssertEqual(candidates[0], "あい", "ひらがなが固定位置0番")
        XCTAssertEqual(candidates[1], "アイ", "カタカナが履歴エントリ（固定位置でなく）")
        XCTAssertEqual(initialRow, 1, "固定候補はひらがなの1件のみ")
    }

    func testReturnCommitsVisuallySelectedCandidateWithoutExplicitNav() {
        handler.db.insertDict(reading: "あい", candidate: "愛", priority: 0)
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        // ↑↓ なし（isExplicitlySelected=false）でも Enter は選択中の候補を確定する
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 2, selectedText: "愛")
        XCTAssertEqual(client.inserted, ["愛"], "Enter は視覚的に選択されている候補を確定する")
    }

    func testTypingDoesNotCommitWhenNotExplicitlySelected() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        // ↑↓ なし（isExplicitlySelected=false）で文字入力 → 候補を確定しない
        type(chars: "k", base: "k", candidateVisible: true, selectedRow: 2, selectedText: "愛")
        XCTAssertTrue(client.inserted.isEmpty, "↑↓ なしで文字入力しても候補を確定しない")
        XCTAssertEqual(client.markedText, "あいk")
    }

    func testSpaceDuringCandidatesFallsBackToShowForSingleSegment() {
        // "あ" は1セグメント → doEnterSegmentMode からフォールバックして .show を返す
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

    // MARK: - ASCII モード（英数キー）

    func testAsciiModeInsertsDirectly() {
        press(keyCode: 102)  // 英数キー
        let result = type(chars: "a", base: "a")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["a"])
        XCTAssertEqual(client.markedText, "")
    }

    func testAsciiModeCommitsComposingFirst() {
        type(chars: "a", base: "a")  // "あ" が未確定
        press(keyCode: 102)          // 英数キーで確定 + ASCII モードへ
        XCTAssertEqual(client.inserted, ["あ"])
    }

    func testEscapeExitsAsciiMode() {
        press(keyCode: 102)   // 英数キー
        press(keyCode: 53)    // Escape → 日本語モードへ
        type(chars: "a", base: "a")
        XCTAssertEqual(client.markedText, "あ")
        XCTAssertTrue(client.inserted.isEmpty)
    }

    // MARK: - Shift + 文字 → 英字を直接挿入

    func testShiftLetterInsertsDirectly() {
        type(chars: "A", base: "a", modifiers: .shift)
        XCTAssertEqual(client.inserted, ["A"])
    }

    func testShiftLetterCommitsComposingFirst() {
        type(chars: "a", base: "a")  // "あ" が未確定
        type(chars: "B", base: "b", modifiers: .shift)
        XCTAssertEqual(client.inserted, ["あ", "B"])
    }

    // MARK: - Shift+記号・非ASCII文字（全角記号など）

    func testFullWidthSymbolInsertedDirectlyWhenEmpty() {
        // 組成なしで全角記号 → 直接挿入
        let result = type(chars: "！", base: "!")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["！"])
        XCTAssertEqual(client.markedText, "")
    }

    func testFullWidthSymbolAppendsToComposition() {
        // 組成中に全角記号 → 組成に追加して確定しない（、。と同じ動作）
        type(chars: "a", base: "a")
        type(chars: "！", base: "!")
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ！")
    }

    func testFullWidthSymbolDoesNotConfirmCandidate() {
        // 候補選択中に全角記号 → 候補を確定せず組成に追加
        handler.db.insertDict(reading: "あ", candidate: "阿", priority: 0)
        type(chars: "a", base: "a")
        let ctx = CandidateContext(isVisible: true, selectedRow: 1, selectedText: "阿", isExplicitlySelected: true)
        _ = handler.handle(keyCode: 0, characters: "！", baseCharacters: "!",
                           modifiers: [], candidate: ctx, client: client)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ！")
    }

    func testShiftSymbolInsertedDirectlyWhenEmpty() {
        // 組成なしで Shift+記号 → 直接挿入
        let result = type(chars: "!", base: "1", modifiers: .shift)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["!"])
    }

    func testShiftSymbolAppendsToComposition() {
        // 組成中に Shift+記号 → 組成に追加して確定しない
        type(chars: "a", base: "a")
        type(chars: "!", base: "1", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ!")
    }

    // MARK: - 句読点変換（, → 、、. → 。）

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
        // 組成中に "." → "。" を組成バッファに追加して候補ウィンドウを開く（変換モードへ）
        type(chars: "a", base: "a")
        let result = type(chars: ".", base: ".")
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ。")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testCommaAppendsToCompositionAndOpensCandidates() {
        // 組成中に "," → "、" を組成バッファに追加して候補ウィンドウを開く（変換モードへ）
        type(chars: "a", base: "a")
        let result = type(chars: ",", base: ",")
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ、")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testPeriodAfterPendingConsonantFlushesPending() {
        // pending "k" がある状態で "." → "k" をフラッシュして "k。" が組成に入り変換モードへ
        type(chars: "k", base: "k")
        let result = type(chars: ".", base: ".")
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "k。")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testPeriodDoesNotCommitSelectedCandidate() {
        // 候補を ↑↓ で明示選択中に "." → 候補は確定せず "。" を組成バッファに追加
        handler.db.insertDict(reading: "あ", candidate: "阿", priority: 0)
        type(chars: "a", base: "a")
        let ctx = CandidateContext(isVisible: true, selectedRow: 1, selectedText: "阿", isExplicitlySelected: true)
        _ = handler.handle(keyCode: 0, characters: ".", baseCharacters: ".",
                           modifiers: [], candidate: ctx, client: client)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ。")
    }

    func testCommaDoesNotCommitSelectedCandidate() {
        // 候補を ↑↓ で明示選択中に "," → 候補は確定せず "、" を組成バッファに追加
        handler.db.insertDict(reading: "あ", candidate: "阿", priority: 0)
        type(chars: "a", base: "a")
        let ctx = CandidateContext(isVisible: true, selectedRow: 1, selectedText: "阿", isExplicitlySelected: true)
        _ = handler.handle(keyCode: 0, characters: ",", baseCharacters: ",",
                           modifiers: [], candidate: ctx, client: client)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ、")
    }

    // MARK: - セグメントモード

    private func typeRomaji(_ s: String) {
        for c in s { type(chars: String(c), base: String(c)) }
    }

    func testSpaceEntersSegmentModeWhenMultipleSegments() {
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        handler.db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)
        typeRomaji("watashihagakusei")
        let (consumed, action) = press(keyCode: 49)  // Space
        XCTAssertTrue(consumed)
        XCTAssertTrue(handler.state.isSegmentMode)
        guard case .show = action else {
            XCTFail("2+セグメントで Space → .show を返すはず: \(action)"); return
        }
    }

    func testSpaceFallsBackToNormalModeForSingleSegment() {
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        typeRomaji("watashi")
        let (consumed, action) = press(keyCode: 49)  // Space
        XCTAssertTrue(consumed)
        XCTAssertFalse(handler.state.isSegmentMode, "1セグメントはセグメントモードに入らないはず")
        guard case .show = action else {
            XCTFail("1セグメントでも .show にフォールバックするはず: \(action)"); return
        }
    }

    func testSegmentModeLeftRightMovesFocus() {
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        handler.db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        XCTAssertEqual(handler.state.segmentState?.focusedIndex, 0)

        press(keyCode: 124)  // Right
        XCTAssertEqual(handler.state.segmentState?.focusedIndex, 1)

        press(keyCode: 124)  // Right
        XCTAssertEqual(handler.state.segmentState?.focusedIndex, 2)

        press(keyCode: 123)  // Left
        XCTAssertEqual(handler.state.segmentState?.focusedIndex, 1)
    }

    func testSegmentModeEnterConfirmsAllSegments() {
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        handler.db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode

        let (consumed, action) = press(keyCode: 36)  // Enter
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.inserted.last, "私は学生")
        XCTAssertFalse(handler.state.isSegmentMode)
        guard case .dismiss = action else {
            XCTFail("確定後は .dismiss を返すはず: \(action)"); return
        }
    }

    func testSegmentModeEscapeRestoresComposing() {
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        handler.db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        XCTAssertTrue(handler.state.isSegmentMode)

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
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        handler.db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        XCTAssertTrue(handler.state.isSegmentMode)

        let (consumed, action) = press(keyCode: 51)  // Backspace
        XCTAssertTrue(consumed)
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertTrue(client.inserted.isEmpty)
        guard case .dismiss = action else {
            XCTFail("Backspace は .dismiss を返すはず: \(action)"); return
        }
    }

    func testSegmentModeHistoryRecordedPerSegment() {
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        handler.db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        press(keyCode: 36)  // Enter → confirm all

        let hist1 = handler.db.fetchCandidates(prefix: "わたし")
        XCTAssertTrue(hist1.candidates.prefix(hist1.historyCount).contains("私"),
                      "「わたし」→「私」が履歴に記録されるはず")

        let hist2 = handler.db.fetchCandidates(prefix: "は")
        XCTAssertTrue(hist2.candidates.prefix(hist2.historyCount).contains("は"),
                      "「は」→「は」が履歴に記録されるはず")

        let hist3 = handler.db.fetchCandidates(prefix: "がくせい")
        XCTAssertTrue(hist3.candidates.prefix(hist3.historyCount).contains("学生"),
                      "「がくせい」→「学生」が履歴に記録されるはず")
    }

    func testCommitCompositionInSegmentMode() {
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        handler.db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        XCTAssertTrue(handler.state.isSegmentMode)

        handler.commitComposition(client: client)
        XCTAssertEqual(client.inserted.last, "私は学生", "deactivateServer 相当の強制確定")
        XCTAssertFalse(handler.state.isSegmentMode)
    }

    // MARK: - セグメント境界調整（Shift+矢印）

    func testSegmentResizeExpandShiftRight() {
        // 初期セグメント: ["わたし", "は", "がくせい"]
        // Shift+Right で "わたし" → "わたしは"、"は" セグメントは消滅
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        handler.db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        XCTAssertTrue(handler.state.isSegmentMode)
        XCTAssertEqual(handler.state.segmentState?.segments[0].reading, "わたし")

        press(keyCode: 124, modifiers: .shift)  // Shift+Right
        guard let ss = handler.state.segmentState else {
            XCTFail("セグメントモードが維持されるはず"); return
        }
        XCTAssertEqual(ss.focusedIndex, 0)
        // "は" (1文字) を奪ったので "わたしは" になり、"は" セグメントは消滅
        XCTAssertEqual(ss.segments[0].reading, "わたしは", "フォーカスセグメントが1文字拡張されるはず")
        XCTAssertEqual(ss.segments[1].reading, "がくせい", "1文字セグメントが消滅して次のセグメントが詰まるはず")
        XCTAssertEqual(ss.segments.count, 2)
    }

    func testSegmentResizeShrinkShiftLeft() {
        // "わたし"+"は"+"がくせい" → Shift+Left で "わたし" を "わた" に縮小
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        handler.db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        XCTAssertTrue(handler.state.isSegmentMode)

        press(keyCode: 123, modifiers: .shift)  // Shift+Left
        guard let ss = handler.state.segmentState else {
            XCTFail("セグメントモードが維持されるはず"); return
        }
        XCTAssertEqual(ss.focusedIndex, 0)
        XCTAssertEqual(ss.segments[0].reading, "わた", "フォーカスセグメントが1文字縮小されるはず")
        XCTAssertEqual(ss.segments[1].reading, "しは", "次セグメントの先頭に末尾文字が渡されるはず")
    }

    func testSegmentResizeShrinkStopsAtOneChar() {
        // 1文字セグメントはこれ以上縮小しない
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        handler.db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        // "は" セグメント（1文字）にフォーカスを移動
        press(keyCode: 124)  // Right → "は"
        guard let ss0 = handler.state.segmentState else { XCTFail(); return }
        let prevCount = ss0.segments.count

        press(keyCode: 123, modifiers: .shift)  // Shift+Left → 縮小不可
        guard let ss = handler.state.segmentState else { XCTFail(); return }
        XCTAssertEqual(ss.segments[ss.focusedIndex].reading, "は", "1文字セグメントは縮小されないはず")
        XCTAssertEqual(ss.segments.count, prevCount)
    }

    func testSegmentResizeExpandMergesNextSegmentWhenEmpty() {
        // 次セグメントが1文字のとき拡張するとそのセグメントが消滅する
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        handler.db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        press(keyCode: 124)  // Right → "は" にフォーカス
        guard let ss0 = handler.state.segmentState else { XCTFail(); return }
        let prevCount = ss0.segments.count

        press(keyCode: 124, modifiers: .shift)  // Shift+Right: "は" → "はが" に拡張
        guard let ss1 = handler.state.segmentState else { XCTFail(); return }
        XCTAssertEqual(ss1.segments[ss1.focusedIndex].reading, "はが")

        // さらに Shift+Right: "はが" → "はがく"
        press(keyCode: 124, modifiers: .shift)
        // もし "がくせい" が1文字ずつ消えていくならセグメント数が同じか減る
        XCTAssertTrue(handler.state.isSegmentMode)
    }

    func testSegmentResizeConfirmAfterResize() {
        // リサイズ後に Enter で確定できる
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        handler.db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode

        press(keyCode: 124, modifiers: .shift)  // Shift+Right: "わたし" → "わたしは"
        press(keyCode: 36)   // Enter → 確定
        XCTAssertFalse(handler.state.isSegmentMode)
        // 確定テキストにはリサイズ後の全セグメントが含まれるはず
        XCTAssertFalse(client.inserted.isEmpty)
    }

    // MARK: - 候補ウィンドウ中のバックスペース・Escape

    func testBackspaceDuringCandidateDisplayDismissesWhenSingleCharRemains() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        // "あい" 表示中にバックスペース → "あ" (1文字) → 候補ウィンドウを閉じる
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
        // "あいう" 表示中にバックスペース → "あい" (2文字以上) → 候補リフレッシュ
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
        let result = handler.db.fetchCandidates(prefix: "あい")
        XCTAssertTrue(result.candidates.prefix(result.historyCount).contains("あい"),
                      "Enter 確定後にひらがなが履歴として記録されるはず")
    }

    func testHistoryRecordedAfterCandidateSelectionAndEnter() {
        handler.db.insertDict(reading: "あ", candidate: "阿", priority: 0)
        type(chars: "a", base: "a")
        press(keyCode: 36, candidateVisible: true, selectedRow: 2, selectedText: "阿")
        let result = handler.db.fetchCandidates(prefix: "あ")
        XCTAssertTrue(result.candidates.prefix(result.historyCount).contains("阿"),
                      "候補選択→Enter 確定後に変換結果が履歴として記録されるはず")
    }

    func testConversionHistoryBoostsNextConversion() {
        // 1回目に選んだ候補が2回目の変換で履歴として先頭に来る
        handler.db.insertDict(reading: "たのしい", candidate: "楽しい", priority: 0)
        typeRomaji("tanoshii")
        press(keyCode: 36, candidateVisible: true, selectedText: "楽しい")  // 楽しい を確定
        typeRomaji("tanoshii")  // 2回目
        let (_, action) = press(keyCode: 49)  // Space
        guard case .show(let candidates, let historyEnd, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.prefix(historyEnd).contains("楽しい"),
                      "前回確定した「楽しい」が次回変換で履歴候補として現れるはず")
    }

    // MARK: - 確定後の再入力

    func testTypingAfterConfirmationStartsFreshComposition() {
        type(chars: "a", base: "a")
        press(keyCode: 36)  // Enter → "あ" 確定
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
        press(keyCode: 102)  // 英数
        XCTAssertTrue(handler.state.isAsciiMode)
        press(keyCode: 104)  // かな
        XCTAssertFalse(handler.state.isAsciiMode)
        type(chars: "a", base: "a")
        XCTAssertEqual(client.markedText, "あ")
        XCTAssertTrue(client.inserted.isEmpty)
    }

    // MARK: - composedHiragana が空のときのスペース

    func testSpacePassesThroughWithOnlyPendingRomaji() {
        type(chars: "k", base: "k")
        XCTAssertEqual(client.markedText, "k")
        let result = press(keyCode: 49)  // Space
        XCTAssertFalse(result.consumed, "composedHiragana が空 (pending のみ) のときスペースはスルーするはず")
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
        handler.db.insertDict(reading: "あ", candidate: "阿", priority: 0)
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

    // っ（促音）の変換
    func testSokuonProducesSmallTsu() {
        typeRomaji("kka")
        XCTAssertEqual(client.markedText, "っか")
    }

    func testSokuonMidWord() {
        typeRomaji("zasshi")
        XCTAssertEqual(client.markedText, "ざっし", "「ざっし」（雑誌）が正しく変換されるはず")
    }

    // ん の自動確定
    func testNAutoFinalizedBeforeConsonant() {
        typeRomaji("kanji")
        XCTAssertEqual(client.markedText, "かんじ", "子音前の n が自動的に「ん」になるはず")
    }

    func testNNPendingNRemainsAfterDoubleN() {
        // "nn" → ん確定 + trailing n は pending のまま（"kanna"→"かんな" のために必要な設計）
        typeRomaji("nn")
        XCTAssertEqual(client.markedText, "んn")
    }

    func testNNThenVowelFinalizesN() {
        // "nn" の後に母音を打つと trailing pending n がひらがなになる
        typeRomaji("nna")
        XCTAssertEqual(client.markedText, "んな")
    }

    func testNBeforeVowelDoesNotProduceN() {
        typeRomaji("na")
        XCTAssertEqual(client.markedText, "な", "na は「な」であり「んa」ではないはず")
    }

    // 拗音
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

    // ↓ で候補を選択して Enter で確定
    func testSelectCandidateWithDownArrowThenEnter() {
        handler.db.insertDict(reading: "あい", candidate: "愛", priority: 0)
        typeRomaji("ai")
        press(keyCode: 49)  // Space → 候補表示

        // ↓ で明示選択して Enter → 「愛」が確定される
        let result = press(keyCode: 36, candidateVisible: true, selectedText: "愛", isExplicitlySelected: true)
        XCTAssertEqual(client.inserted, ["愛"])
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず"); return
        }
    }

    // カタカナを候補から選択して確定
    func testSelectKatakanaCandidate() {
        typeRomaji("ai")
        // 「アイ」を明示選択して Enter
        press(keyCode: 36, candidateVisible: true, selectedText: "アイ", isExplicitlySelected: true)
        XCTAssertEqual(client.inserted, ["アイ"], "カタカナ候補を確定できるはず")
    }

    // 変換候補なし（辞書未登録）でもひらがな・カタカナが候補に出る
    func testSpaceWithUnknownReadingShowsHiraganaAndKatakana() {
        // 1文字なら必ず単一セグメント → 候補は入力ひらがな全体で表示される
        type(chars: "u", base: "u")
        let (consumed, action) = press(keyCode: 49)  // Space
        XCTAssertTrue(consumed)
        guard case .show(let candidates, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.contains("う"), "ひらがなが候補に含まれるはず: \(candidates)")
        XCTAssertTrue(candidates.contains("ウ"), "カタカナが候補に含まれるはず: \(candidates)")
    }

    // 確定後すぐ続けて別の単語を入力
    func testContinuousInputAfterConfirmation() {
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        typeRomaji("watashi")
        press(keyCode: 36, candidateVisible: true, selectedText: "私", isExplicitlySelected: true)
        XCTAssertEqual(client.inserted, ["私"])

        // 続けて入力
        typeRomaji("ha")
        XCTAssertEqual(client.markedText, "は")
        XCTAssertEqual(client.inserted, ["私"], "新しい組成が始まり、追加挿入はないはず")
    }

    // 組成中の Backspace で hiragana を一文字ずつ削除
    func testBackspaceOneByOneFromComposition() {
        typeRomaji("uta")
        XCTAssertEqual(client.markedText, "うた")
        press(keyCode: 51)
        XCTAssertEqual(client.markedText, "う")
        press(keyCode: 51)
        XCTAssertEqual(client.markedText, "")
    }

    // 動詞活用形の変換（送り仮名付き）
    func testVerbOkuriganaConversion() {
        handler.db.insertDict(reading: "かき", candidate: "書き", priority: 0)
        typeRomaji("kaki")
        XCTAssertEqual(client.markedText, "かき")
        let (_, action) = press(keyCode: 49)  // Space
        guard case .show(let candidates, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.contains("書き"), "「書き」が候補に含まれるはず: \(candidates)")
    }

    // 複数候補の中から2番目以降の候補を選択して確定
    func testSelectSecondCandidateFromMultiple() {
        handler.db.insertDict(reading: "かいぎ", candidate: "会議", priority: 0)
        handler.db.insertDict(reading: "かいぎ", candidate: "懐疑", priority: 1)
        typeRomaji("kaigi")
        press(keyCode: 49)  // Space → 候補表示

        // 「懐疑」を明示的に選んで確定
        press(keyCode: 36, candidateVisible: true, selectedText: "懐疑", isExplicitlySelected: true)
        XCTAssertEqual(client.inserted, ["懐疑"])
    }

    // セグメントモードで特定セグメントの候補を変更して確定
    func testSegmentModeCandidateChangePerSegment() {
        handler.db.insertDict(reading: "とうきょう", candidate: "東京", priority: 0)
        handler.db.insertDict(reading: "えき", candidate: "駅", priority: 0)
        typeRomaji("toukyoueki")
        press(keyCode: 49)  // Space → セグメントモード
        guard handler.state.isSegmentMode else {
            XCTFail("セグメントモードに入るはず"); return
        }

        // 2つ目のセグメント（えき）にフォーカスを移動
        press(keyCode: 124)  // Right
        // 「駅」を明示選択して Enter
        press(keyCode: 36, candidateVisible: true, selectedText: "駅", isExplicitlySelected: true)
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertEqual(client.inserted.last, "東京駅")
    }

    // 一文を通しで入力して変換
    func testFullSentenceConversion() {
        handler.db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        handler.db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → セグメントモード
        press(keyCode: 36)  // Enter → 全確定
        XCTAssertEqual(client.inserted.last, "私は学生")
    }
}
