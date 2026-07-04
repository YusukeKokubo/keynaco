import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

// See: docs/domain/states.md#状態一覧
// See: docs/domain/glossary.md#ascii-モード
// See: docs/domain/scenarios.md#s-04-shift文字日本語モードで英字組成

final class InputHandlerAsciiTests: InputHandlerTestCase {

    // MARK: - ASCII モード（英数キー）
    // See: docs/domain/states.md#状態一覧
    // See: docs/domain/glossary.md#ascii-モード

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

    // MARK: - activateServer 直後のモードキー echo（ignoreNextModeSwitch）

    func testSpuriousEisuAfterActivationIgnored() {
        InputHandler.isAsciiMode = false
        handler.ignoreNextModeSwitch = true
        let result = press(keyCode: 102)
        XCTAssertTrue(result.consumed)
        XCTAssertFalse(InputHandler.isAsciiMode, "echo された英数は ASCII モードにしてはいけない")
        XCTAssertFalse(handler.ignoreNextModeSwitch)
    }

    func testSpuriousKanaAfterActivationIgnored() {
        InputHandler.isAsciiMode = true
        handler.ignoreNextModeSwitch = true
        let result = press(keyCode: 104)
        XCTAssertTrue(result.consumed)
        XCTAssertTrue(InputHandler.isAsciiMode, "echo されたかなは日本語モードへ戻してはいけない")
        XCTAssertFalse(handler.ignoreNextModeSwitch)
    }

    func testModeSwitchHonoredAfterIgnoredEcho() {
        InputHandler.isAsciiMode = false
        handler.ignoreNextModeSwitch = true
        press(keyCode: 102)
        press(keyCode: 102)
        XCTAssertTrue(InputHandler.isAsciiMode, "2 回目の英数は通常どおり ASCII モードへ")
    }

    /// 英数/かな以外のキーでも take で消費される（echo 待ちのまま残さない）。
    func testNonModeKeyConsumesIgnoreNextModeSwitch() {
        InputHandler.isAsciiMode = false
        handler.ignoreNextModeSwitch = true
        _ = type(chars: "a", base: "a")
        XCTAssertFalse(handler.ignoreNextModeSwitch)
        press(keyCode: 102)
        XCTAssertTrue(InputHandler.isAsciiMode, "フラグ消費後の英数は通常どおり ASCII モードへ")
    }

    // MARK: - Shift + 文字 → 組成バッファに英字として貯める
    // See: docs/domain/scenarios.md#s-04-shift文字日本語モードで英字組成

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
        _ = handleAndApply(keyCode: 0, characters: "！", baseCharacters: "!", candidate: ctx)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "あ！")
    }

    func testShiftSymbolInsertedDirectlyWhenEmpty() {
        let result = type(chars: "!", base: "1", modifiers: .shift)
        XCTAssertTrue(result.consumed)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(client.markedText, "！")
        if case .show = result.candidateAction { } else {
            XCTFail("Expected .show candidateAction but got \(result.candidateAction)")
        }
    }

    func testShiftSymbolAppendsToComposition() {
        type(chars: "a", base: "a")
        type(chars: "!", base: "1", modifiers: .shift)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertEqual(handler.state.composedHiragana, "あ！")
    }

    // MARK: - ASCII 英字学習（案4）

    func testAsciiInputHistoryStoredLowercase() {
        // Shift+A, P, I → composedHiragana = "API" → Enter で確定
        type(chars: "A", base: "a", modifiers: .shift)
        type(chars: "P", base: "p", modifiers: .shift)
        type(chars: "I", base: "i", modifiers: .shift)
        press(keyCode: 36)  // Enter

        // input キーが小文字 "api" で記録されること
        let results = handler.db.exactOutputs(reading: "api")
        XCTAssertEqual(results, ["API"], "ASCII 入力は小文字キーで記録される")

        // 大文字で引いても COLLATE NOCASE により取得できること
        let upperResults = handler.db.exactOutputs(reading: "API")
        XCTAssertEqual(upperResults, ["API"])
    }

    func testAsciiInputPrefixMatchReturnsUppercaseOutput() {
        // Shift+G, I, T, H, U, B → "GITHUB" を確定（input:"github" で記録）
        for (ch, base) in [("G","g"),("I","i"),("T","t"),("H","h"),("U","u"),("B","b")] {
            type(chars: ch, base: base, modifiers: .shift)
        }
        press(keyCode: 36)  // Enter

        // GITHUB は g-i-t-h-u-b: prefix "gi" で絞り込める
        let results = handler.db.mergedOutputs(reading: "gi")
        XCTAssertTrue(results.contains("GITHUB"), "prefix 'gi' で GITHUB が候補に出る: \(results)")

        // さらに短い prefix "g" でも引ける（Shift+G 1打で GITHUB が候補に出ること）
        let resultsG = handler.db.mergedOutputs(reading: "g")
        XCTAssertTrue(resultsG.contains("GITHUB"), "prefix 'g' で GITHUB が候補に出る: \(resultsG)")
    }

    // MARK: - 英字単語モード（Shift 起動 + 小文字継続）
    // See: docs/domain/scenarios.md#s-04-shift文字日本語モードで英字組成

    func testGitHubMixedCaseMarkedText() {
        // Shift+G → 全ASCII組成開始、以降の小文字もそのまま蓄積される
        type(chars: "G", base: "g", modifiers: .shift)
        XCTAssertEqual(client.markedText, "G")
        type(chars: "i", base: "i")
        XCTAssertEqual(client.markedText, "Gi")
        type(chars: "t", base: "t")
        XCTAssertEqual(client.markedText, "Git")
        type(chars: "H", base: "h", modifiers: .shift)
        XCTAssertEqual(client.markedText, "GitH")
        type(chars: "u", base: "u")
        XCTAssertEqual(client.markedText, "GitHu")
        type(chars: "b", base: "b")
        XCTAssertEqual(client.markedText, "GitHub")
    }

    func testGitHubConfirmsExactString() {
        type(chars: "G", base: "g", modifiers: .shift)
        type(chars: "i", base: "i")
        type(chars: "t", base: "t")
        type(chars: "H", base: "h", modifiers: .shift)
        type(chars: "u", base: "u")
        type(chars: "b", base: "b")
        press(keyCode: 36)  // Enter
        XCTAssertEqual(client.inserted.last, "GitHub")
    }

    func testGitHubRecordedInHistory() {
        type(chars: "G", base: "g", modifiers: .shift)
        type(chars: "i", base: "i")
        type(chars: "t", base: "t")
        type(chars: "H", base: "h", modifiers: .shift)
        type(chars: "u", base: "u")
        type(chars: "b", base: "b")
        press(keyCode: 36)  // Enter

        // historyKey は小文字正規化されるので "github" で検索
        let exact = handler.db.exactOutputs(reading: "github")
        XCTAssertTrue(exact.contains("GitHub"), "exact 'github' → GitHub: \(exact)")
    }

    func testLowercaseStartStillDoesRomaji() {
        // 小文字始まり（Shift なし）はローマ字変換される（英字単語モードに入らない）
        type(chars: "g", base: "g")
        type(chars: "o", base: "o")
        XCTAssertEqual(client.markedText, "ご")
    }

    func testMixedHiraganaAndAsciiNotNormalized() {
        // ひらがな混在の input は小文字化されない（記録はそのまま "あAPI"）
        typeRomaji("a")  // → composedHiragana = "あ"
        type(chars: "A", base: "a", modifiers: .shift)
        type(chars: "P", base: "p", modifiers: .shift)
        type(chars: "I", base: "i", modifiers: .shift)
        press(keyCode: 36)  // Enter → input:"あAPI", output:"あAPI"

        // 元のキーで取得できる
        let original = handler.db.exactOutputs(reading: "あAPI")
        XCTAssertEqual(original, ["あAPI"])
    }
}
