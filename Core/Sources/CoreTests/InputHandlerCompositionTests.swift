import XCTest
@testable import KeynacoCore

// See: docs/domain/states.md#組成中
// See: docs/domain/scenarios.md#s-01-基本的なローマ字変換

final class InputHandlerCompositionTests: InputHandlerTestCase {

    // MARK: - ローマ字 → ひらがな変換
    // See: docs/domain/states.md#組成中
    // See: docs/domain/scenarios.md#s-01-基本的なローマ字変換

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
        guard case .show(let candidates, _, _, _, _) = action else {
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
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("履歴ありなら自動表示するはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("あい"))
    }

    // MARK: - Return で確定
    // See: docs/domain/states.md#組成中

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
    // See: docs/domain/states.md#組成中

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
    // See: docs/domain/states.md#組成中

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

    // MARK: - 句読点変換
    // See: docs/domain/glossary.md#組成テキストmarkedtext

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
    // See: docs/domain/glossary.md#組成テキストmarkedtext

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

    // MARK: - 括弧変換（組成なし → 候補ウィンドウ）

    func testOpenBracketShowsCandidateWindow() {
        // "[" → 候補ウィンドウが開き marked text に先頭候補「「」が表示される
        let result = type(chars: "[", base: "[")
        XCTAssertTrue(result.consumed)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "「")
        if case .show(let candidates, _, _, _, _) = result.candidateAction {
            XCTAssertTrue(candidates.contains("「"))
            XCTAssertTrue(candidates.contains("【"))
        } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testCloseBracketShowsCandidateWindow() {
        let result = type(chars: "]", base: "]")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "」")
        if case .show(let candidates, _, _, _, _) = result.candidateAction {
            XCTAssertTrue(candidates.contains("」"))
            XCTAssertTrue(candidates.contains("】"))
        } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testOpenParenShowsCandidateWindow() {
        // Shift+9 → "（" の候補ウィンドウ
        let result = type(chars: "(", base: "9", modifiers: .shift)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "（")
        if case .show(let candidates, _, _, _, _) = result.candidateAction {
            XCTAssertTrue(candidates.contains("（"))
        } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testBracketEnterConfirmsSelection() {
        // "[" → Enter で先頭候補「「」を確定
        type(chars: "[", base: "[")
        let ctx = CandidateContext(isVisible: true, selectedRow: 0, selectedText: "「")
        _ = handler.handle(keyCode: KeyCode.enter, characters: nil, baseCharacters: nil,
                           modifiers: [], candidate: ctx, client: client)
        XCTAssertEqual(client.inserted, ["「"])
        XCTAssertFalse(handler.isBracketMode)
    }

    func testBracketEscapeCancels() {
        // "[" → Escape でキャンセル、何も挿入されない
        type(chars: "[", base: "[")
        let ctx = CandidateContext(isVisible: true, selectedRow: 0, selectedText: "「")
        _ = handler.handle(keyCode: KeyCode.escape, characters: nil, baseCharacters: nil,
                           modifiers: [], candidate: ctx, client: client)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "")
        XCTAssertFalse(handler.isBracketMode)
    }

    func testBracketSelectionThenNextChar() {
        // "[" → 候補選択中に次の文字を押すと括弧を確定して通常組成を開始
        type(chars: "[", base: "[")
        let ctx = CandidateContext(isVisible: true, selectedRow: 1, selectedText: "【")
        _ = handler.handle(keyCode: 0, characters: "a", baseCharacters: "a",
                           modifiers: [], candidate: ctx, client: client)
        XCTAssertEqual(client.inserted, ["【"])
        XCTAssertEqual(client.markedText, "あ")
        XCTAssertFalse(handler.isBracketMode)
    }

    // MARK: - 括弧変換（組成あり → 先頭候補を末尾に追加）

    func testBracketAppendsToComposition() {
        type(chars: "a", base: "a")
        let result = type(chars: "[", base: "[")
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ「")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testParenAppendsToComposition() {
        type(chars: "a", base: "a")
        let result = type(chars: "(", base: "9", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ（")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testBracketAfterPendingConsonantFlushesPending() {
        type(chars: "k", base: "k")
        let result = type(chars: "[", base: "[")
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "k「")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
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
    // See: docs/domain/scenarios.md#s-01-基本的なローマ字変換

    func testLongVowelMarkAppendsToComposition() {
        type(chars: "r", base: "r")
        type(chars: "a", base: "a")
        type(chars: "-", base: "-")
        XCTAssertEqual(client.markedText, "らー", "ハイフンが長音符「ー」に変換されるはず")
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
    // See: docs/domain/scenarios.md#s-01-基本的なローマ字変換
    // See: docs/domain/glossary.md#pendinromaji

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

    func testNNShowsNWithoutPending() {
        // 標準IME準拠: "nn" 後は "ん" のみ表示（pending "n" は非表示）
        typeRomaji("nn")
        XCTAssertEqual(client.markedText, "ん")
    }

    func testNNThenVowelFinalizesN() {
        typeRomaji("nna")
        XCTAssertEqual(client.markedText, "んな")
    }

    func testKonnnaProducesKonna() {
        // "konnna": nn→ん、3つ目のnはhidden nを破棄して新しいpendingに。na→な
        typeRomaji("konnna")
        XCTAssertEqual(client.markedText, "こんな")
    }

    func testKonnichiwa() {
        // hidden "n" + 母音 は通常どおり組み合わせ
        typeRomaji("konnichiwa")
        XCTAssertEqual(client.markedText, "こんにちわ")
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
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.contains("書き"), "「書き」が候補に含まれるはず: \(candidates)")
    }

    // MARK: - F6〜F10 変換確定
    // See: docs/domain/states.md#組成中
    // See: docs/domain/scenarios.md#s-07-f-キーで即時確定

    func testF6ConfirmsHiragana() {
        typeRomaji("ka")
        let (consumed, _) = press(keyCode: KeyCode.f6)
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.inserted.last, "か")
        XCTAssertTrue(handler.state.composingText.isEmpty)
    }

    func testF7ConfirmsKatakana() {
        typeRomaji("ka")
        let (consumed, _) = press(keyCode: KeyCode.f7)
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.inserted.last, "カ")
        XCTAssertTrue(handler.state.composingText.isEmpty)
    }

    func testF8ConfirmsHankakuKatakana() {
        typeRomaji("ka")
        let (consumed, _) = press(keyCode: KeyCode.f8)
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.inserted.last, "ｶ")
        XCTAssertTrue(handler.state.composingText.isEmpty)
    }

    func testF9ConfirmsZenkakuAscii() {
        typeRomaji("nihon")
        let (consumed, _) = press(keyCode: KeyCode.f9)
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.inserted.last, "ｎｉｈｏｎ")
        XCTAssertTrue(handler.state.composingText.isEmpty)
    }

    func testF10ConfirmsHankakuAscii() {
        typeRomaji("nihon")
        let (consumed, _) = press(keyCode: KeyCode.f10)
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.inserted.last, "nihon")
        XCTAssertTrue(handler.state.composingText.isEmpty)
    }

    func testFunctionKeyForceFinalizesPendingRomaji() {
        // pendingRomaji="n" の状態で F7 → forceFinalize("n")="ん" → "ン" で確定
        type(chars: "n", base: "n")
        XCTAssertEqual(handler.state.pendingRomaji, "n")
        let (consumed, _) = press(keyCode: KeyCode.f7)
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.inserted.last, "ン")
    }

    func testFunctionKeyIgnoredWhenCompositionEmpty() {
        // 組成テキストが空なら F7 は消費しない
        let (consumed, action) = press(keyCode: KeyCode.f7)
        XCTAssertFalse(consumed)
        guard case .none = action else {
            XCTFail("組成空で F7 は .none を返すはず: \(action)"); return
        }
    }

    func testFunctionKeyIgnoredInAsciiMode() {
        // ASCII モードでは F6〜F10 は無効（組成テキストがないため consumed=false）
        InputHandler.isAsciiMode = true
        let (consumed, action) = press(keyCode: KeyCode.f7)
        XCTAssertFalse(consumed)
        guard case .none = action else {
            XCTFail("ASCII モードで F7 は .none を返すはず: \(action)"); return
        }
    }

    // MARK: - 括弧モード中の F キー・Shift+Delete

    func testBracketModeFKeyInsertsBracketAndClearsMode() {
        // 括弧モード中に F7 → 選択中の括弧が挿入されてモード解除（F7 自体は composing 空で無効）
        type(chars: "[", base: "[")
        XCTAssertTrue(handler.isBracketMode)
        let selectedBracket = "「"
        let ctx = CandidateContext(isVisible: true, selectedRow: 0, selectedText: selectedBracket)
        _ = handler.handle(keyCode: KeyCode.f7, characters: nil, baseCharacters: nil,
                           modifiers: [], candidate: ctx, client: client)
        XCTAssertFalse(handler.isBracketMode, "F キー後は括弧モードが解除されるはず")
        XCTAssertEqual(client.inserted.last, selectedBracket, "選択中の括弧が挿入されるはず")
    }

    func testBracketModeShiftDeleteDismisses() {
        // 括弧モード中に Shift+Delete（backspace keyCode + shift）→ Escape と同様にモード解除
        type(chars: "[", base: "[")
        XCTAssertTrue(handler.isBracketMode)
        let result = press(keyCode: KeyCode.backspace, modifiers: .shift, candidateVisible: true)
        XCTAssertFalse(handler.isBracketMode, "Shift+Delete で括弧モードが解除されるはず")
        XCTAssertTrue(client.inserted.isEmpty, "Shift+Delete では括弧は挿入されないはず")
        guard case .dismiss = result.candidateAction else {
            XCTFail("Shift+Delete は .dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    // MARK: - Shift+句読点確定後の Successor モード非起動

    func testShiftAngleBracketConfirmedNotNounLikeNoSuccessor() {
        // `<` 確定後は isNounLike("<") = false → Successor モードは起動しない
        type(chars: "<", base: ",", modifiers: .shift)
        let result = press(keyCode: KeyCode.enter)
        XCTAssertFalse(handler.isSuccessorMode, "「<」は名詞でないため Successor モードは起動しないはず")
        XCTAssertEqual(client.inserted.last, "<")
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず: \(result.candidateAction)"); return
        }
    }
}
