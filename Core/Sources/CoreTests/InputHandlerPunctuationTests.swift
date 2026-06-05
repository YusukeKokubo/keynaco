import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

// 句読点・括弧・F6–F10・括弧モード周り。docs/domain/glossary.md#組成テキストmarkedtext 等。

final class InputHandlerPunctuationTests: InputHandlerTestCase {

    // MARK: - 句読点変換
    // See: docs/domain/glossary.md#組成テキストmarkedtext

    func testPeriodShowsCandidateWindow() {
        let result = type(chars: ".", base: ".")
        XCTAssertTrue(result.consumed)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "。")
        if let payload = result.candidateAction.showPayload {
            XCTAssertTrue(payload.candidates.contains("。"))
            XCTAssertTrue(payload.candidates.contains("."))
        } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testCommaShowsCandidateWindow() {
        let result = type(chars: ",", base: ",")
        XCTAssertTrue(result.consumed)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "、")
        if let payload = result.candidateAction.showPayload {
            XCTAssertTrue(payload.candidates.contains("、"))
            XCTAssertTrue(payload.candidates.contains(","))
        } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
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
        _ = handleAndApply(keyCode: 0, characters: ".", baseCharacters: ".", candidate: ctx)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ。")
    }

    func testCommaDoesNotCommitSelectedCandidate() {
        type(chars: "a", base: "a")
        let ctx = CandidateContext(isVisible: true, selectedRow: 1, selectedText: "阿", isExplicitlySelected: true)
        _ = handleAndApply(keyCode: 0, characters: ",", baseCharacters: ",", candidate: ctx)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ、")
    }

    // MARK: - Shift+句読点キー → 全角記号候補ウィンドウ

    func testShiftCommaShowsLessThanCandidates() {
        let result = type(chars: "<", base: ",", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "＜")
        if let payload = result.candidateAction.showPayload {
            XCTAssertTrue(payload.candidates.contains("＜"))
        } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testShiftPeriodShowsGreaterThanCandidates() {
        let result = type(chars: ">", base: ".", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "＞")
        if let payload = result.candidateAction.showPayload {
            XCTAssertTrue(payload.candidates.contains("＞"))
        } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testShiftCommaAppendsToJapaneseComposition() {
        type(chars: "a", base: "a")
        type(chars: "<", base: ",", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ＜")
    }

    func testCommaWithoutShiftShowsCandidateWindow() {
        let result = type(chars: ",", base: ",")
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "、")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testPeriodWithoutShiftShowsCandidateWindow() {
        let result = type(chars: ".", base: ".")
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "。")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    // MARK: - 括弧変換（組成なし → 候補ウィンドウ）

    func testOpenBracketShowsCandidateWindow() {
        let result = type(chars: "[", base: "[")
        XCTAssertTrue(result.consumed)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "「")
        if let payload = result.candidateAction.showPayload {
            XCTAssertTrue(payload.candidates.contains("「"))
            XCTAssertTrue(payload.candidates.contains("【"))
        } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testCloseBracketShowsCandidateWindow() {
        let result = type(chars: "]", base: "]")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "」")
        if let payload = result.candidateAction.showPayload {
            XCTAssertTrue(payload.candidates.contains("」"))
            XCTAssertTrue(payload.candidates.contains("】"))
        } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testOpenParenShowsCandidateWindow() {
        let result = type(chars: "(", base: "9", modifiers: .shift)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "（")
        if let payload = result.candidateAction.showPayload {
            XCTAssertTrue(payload.candidates.contains("（"))
        } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testBracketEnterConfirmsSelection() {
        type(chars: "[", base: "[")
        let ctx = CandidateContext(isVisible: true, selectedRow: 0, selectedText: "「")
        _ = handleAndApply(keyCode: KeyCode.enter, candidate: ctx)
        XCTAssertEqual(client.inserted, ["「"])
        XCTAssertFalse(handler.isBracketMode)
    }

    func testBracketEscapeCancels() {
        type(chars: "[", base: "[")
        let ctx = CandidateContext(isVisible: true, selectedRow: 0, selectedText: "「")
        _ = handleAndApply(keyCode: KeyCode.escape, candidate: ctx)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "")
        XCTAssertFalse(handler.isBracketMode)
    }

    func testBracketSelectionThenNextChar() {
        type(chars: "[", base: "[")
        let ctx = CandidateContext(isVisible: true, selectedRow: 1, selectedText: "【")
        _ = handleAndApply(keyCode: 0, characters: "a", baseCharacters: "a", candidate: ctx)
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
        type(chars: "n", base: "n")
        XCTAssertEqual(handler.state.pendingRomaji, "n")
        let (consumed, _) = press(keyCode: KeyCode.f7)
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.inserted.last, "ン")
    }

    func testFunctionKeyIgnoredWhenCompositionEmpty() {
        let (consumed, action) = press(keyCode: KeyCode.f7)
        XCTAssertFalse(consumed)
        guard case .none = action else {
            XCTFail("組成空で F7 は .none を返すはず: \(action)"); return
        }
    }

    func testFunctionKeyIgnoredInAsciiMode() {
        InputHandler.isAsciiMode = true
        let (consumed, action) = press(keyCode: KeyCode.f7)
        XCTAssertFalse(consumed)
        guard case .none = action else {
            XCTFail("ASCII モードで F7 は .none を返すはず: \(action)"); return
        }
    }

    // MARK: - 括弧モード中の F キー・Shift+Delete

    func testBracketModeFKeyInsertsBracketAndClearsMode() {
        type(chars: "[", base: "[")
        XCTAssertTrue(handler.isBracketMode)
        let selectedBracket = "「"
        let ctx = CandidateContext(isVisible: true, selectedRow: 0, selectedText: selectedBracket)
        _ = handleAndApply(keyCode: KeyCode.f7, candidate: ctx)
        XCTAssertFalse(handler.isBracketMode, "F キー後は括弧モードが解除されるはず")
        XCTAssertEqual(client.inserted.last, selectedBracket, "選択中の括弧が挿入されるはず")
    }

    func testBracketModeShiftDeleteDismisses() {
        type(chars: "[", base: "[")
        XCTAssertTrue(handler.isBracketMode)
        let result = press(keyCode: KeyCode.backspace, modifiers: .shift, candidateVisible: true)
        XCTAssertFalse(handler.isBracketMode, "Shift+Delete で括弧モードが解除されるはず")
        XCTAssertTrue(client.inserted.isEmpty, "Shift+Delete では括弧は挿入されないはず")
        guard case .dismiss = result.candidateAction else {
            XCTFail("Shift+Delete は .dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    // MARK: - Shift+/ → ？候補ウィンドウ、Shift+1 → ！候補ウィンドウ

    func testShiftSlashShowsCandidateWindow() {
        let result = type(chars: "?", base: "?", modifiers: .shift)
        XCTAssertTrue(result.consumed)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "？")
        if let payload = result.candidateAction.showPayload {
            XCTAssertTrue(payload.candidates.contains("？"))
            XCTAssertTrue(payload.candidates.contains("?"))
        } else {
            XCTFail("Expected .show but got \(result.candidateAction)")
        }
    }

    func testShiftSlashUSKeyboardShowsCandidateWindow() {
        // US キーボード: Shift+/ → chars="?", base="/"
        let result = type(chars: "?", base: "/", modifiers: .shift)
        XCTAssertTrue(result.consumed)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "？")
        if let payload = result.candidateAction.showPayload {
            XCTAssertTrue(payload.candidates.contains("？"))
            XCTAssertTrue(payload.candidates.contains("?"))
        } else {
            XCTFail("Expected .show but got \(result.candidateAction)")
        }
    }

    func testShiftSlashUSKeyboardAppendsToComposition() {
        type(chars: "a", base: "a")
        let result = type(chars: "?", base: "/", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ？")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show but got \(result.candidateAction)")
        }
    }

    func testShiftOneShowsCandidateWindow() {
        let result = type(chars: "!", base: "!", modifiers: .shift)
        XCTAssertTrue(result.consumed)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "！")
        if let payload = result.candidateAction.showPayload {
            XCTAssertTrue(payload.candidates.contains("！"))
            XCTAssertTrue(payload.candidates.contains("!"))
        } else {
            XCTFail("Expected .show but got \(result.candidateAction)")
        }
    }


    func testShiftSlashAppendsToComposition() {
        type(chars: "a", base: "a")
        let result = type(chars: "?", base: "?", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ？")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show but got \(result.candidateAction)")
        }
    }

    func testShiftOneAppendsToComposition() {
        type(chars: "a", base: "a")
        let result = type(chars: "!", base: "!", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ！")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show but got \(result.candidateAction)")
        }
    }

    // MARK: - Shift+句読点確定後は候補ウィンドウを残さない

    func testShiftAngleBracketConfirmedDismissesCandidates() {
        type(chars: "<", base: ",", modifiers: .shift)
        let result = press(keyCode: KeyCode.enter)
        XCTAssertEqual(client.inserted.last, "＜")
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず: \(result.candidateAction)"); return
        }
    }
}
