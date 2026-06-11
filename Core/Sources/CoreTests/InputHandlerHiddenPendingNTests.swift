import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

/// `nn` 後の hidden pending `n` が Space / 句読点 / F6 / 括弧で二重「ん」にならないこと。
final class InputHandlerHiddenPendingNTests: InputHandlerTestCase {

    func testNNPlusSpaceDoesNotDoubleNInComposed() {
        typeRomaji("nn")
        XCTAssertTrue(handler.state.hiddenPendingN)
        _ = press(keyCode: KeyCode.space)
        XCTAssertEqual(handler.state.composedHiragana, "ん")
        XCTAssertFalse(handler.state.hiddenPendingN)
        XCTAssertEqual(handler.state.pendingRomaji, "")
    }

    func testNNPlusCommaClearsHiddenFlagAndSingleN() {
        typeRomaji("nn")
        XCTAssertTrue(handler.state.hiddenPendingN)
        _ = type(chars: ",", base: ",")
        XCTAssertEqual(handler.state.composedHiragana, "ん、")
        XCTAssertFalse(handler.state.hiddenPendingN)
    }

    func testNNPlusBracketFlushDoesNotDoubleN() {
        typeRomaji("nn")
        _ = type(chars: "[", base: "[")
        XCTAssertEqual(handler.state.composedHiragana, "ん「")
        XCTAssertFalse(handler.state.hiddenPendingN)
    }

    func testNNPlusF6CommitsSingleHiraganaN() {
        typeRomaji("nn")
        let (consumed, _) = press(keyCode: KeyCode.f6)
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.inserted.last, "ん")
        XCTAssertFalse(handler.state.isComposing)
    }
}
