import XCTest
@testable import keynaco

final class ShiftInputTests: XCTestCase {

    // MARK: - RomajiConverter の lowercase 動作

    func testRomajiConverterLowercasesInput() {
        // RomajiConverter は入力を lowercased() するため大文字を渡しても「あ」になる
        // これが Shift+A → "あ" になるバグの根本原因
        let result = RomajiConverter.convert("A")
        XCTAssertEqual(result.converted, "あ", "大文字 A は lowercase されて「あ」になる")
        XCTAssertEqual(result.pending, "")
    }

    // MARK: - Shift 検出（characters vs baseCharacters の比較）

    func testShiftDetectedForUppercaseLetter() {
        // Shift+A: characters="A", charactersIgnoringModifiers="a" → Shift あり
        XCTAssertTrue(CompositionState.isShiftInput(characters: "A", baseCharacters: "a"))
    }

    func testNoShiftForLowercaseLetter() {
        // a: characters="a", charactersIgnoringModifiers="a" → Shift なし
        XCTAssertFalse(CompositionState.isShiftInput(characters: "a", baseCharacters: "a"))
    }

    func testShiftDetectedForSymbol() {
        // Shift+1="!" vs "1" → Shift あり
        XCTAssertTrue(CompositionState.isShiftInput(characters: "!", baseCharacters: "1"))
    }

    func testNoShiftWhenCharsSame() {
        // 変化なし → Shift なし
        XCTAssertFalse(CompositionState.isShiftInput(characters: "1", baseCharacters: "1"))
    }
}
