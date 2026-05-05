import XCTest
@testable import keynaco

final class InputHandlerZSequenceTests: InputHandlerTestCase {

    // MARK: - 待機中（composedHiragana 空）

    func testZDash_insertsWaveDash() {
        type(chars: "z", base: "z")
        type(chars: "-", base: "-")
        XCTAssertEqual(client.inserted, ["〜"])
        XCTAssertEqual(client.markedText, "")
    }

    func testZSlash_insertsMidDot() {
        type(chars: "z", base: "z")
        type(chars: "/", base: "/")
        XCTAssertEqual(client.inserted, ["・"])
    }

    func testZDot_insertsEllipsis() {
        type(chars: "z", base: "z")
        type(chars: ".", base: ".")
        XCTAssertEqual(client.inserted, ["…"])
    }

    func testZComma_insertsIdeographicComma() {
        type(chars: "z", base: "z")
        type(chars: ",", base: ",")
        XCTAssertEqual(client.inserted, ["、"])
    }

    func testZRightArrow_insertsRightArrow() {
        type(chars: "z", base: "z")
        press(keyCode: KeyCode.rightArrow)
        XCTAssertEqual(client.inserted, ["→"])
    }

    func testZLeftArrow_insertsLeftArrow() {
        type(chars: "z", base: "z")
        press(keyCode: KeyCode.leftArrow)
        XCTAssertEqual(client.inserted, ["←"])
    }

    // MARK: - 組成中（composedHiragana あり）

    func testZDash_appendsToComposition() {
        typeRomaji("ka")
        XCTAssertEqual(client.markedText, "か")
        type(chars: "z", base: "z")
        type(chars: "-", base: "-")
        XCTAssertEqual(client.inserted, [])
        XCTAssertTrue(client.markedText.hasPrefix("か〜"))
    }

    func testZRightArrow_appendsToComposition() {
        typeRomaji("ka")
        type(chars: "z", base: "z")
        press(keyCode: KeyCode.rightArrow)
        XCTAssertEqual(client.inserted, [])
        XCTAssertTrue(client.markedText.hasPrefix("か→"))
    }

    // MARK: - z 以外の pending では無効

    func testNonZPendingDashDoesNotTrigger() {
        type(chars: "k", base: "k")
        type(chars: "-", base: "-")
        // k + - は z シーケンスではないので通常動作（ー が composedHiragana に入る）
        XCTAssertEqual(client.inserted, [])
        XCTAssertTrue(client.markedText.contains("ー") || client.markedText.contains("k"))
    }

    // MARK: - z が pending でなければ矢印は通常通りパススルー

    func testArrowWithoutZPending_passesThrough() {
        let result = press(keyCode: KeyCode.rightArrow)
        XCTAssertFalse(result.consumed)
        XCTAssertTrue(client.inserted.isEmpty)
    }
}
