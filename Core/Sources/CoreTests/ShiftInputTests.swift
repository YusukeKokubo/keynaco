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


}
