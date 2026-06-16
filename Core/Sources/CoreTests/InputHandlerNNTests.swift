import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

/// `nn` 確定後の Space / 句読点 / F6 / 括弧で二重「ん」にならないこと。
final class InputHandlerNNTests: InputHandlerTestCase {

    func testNNPlusSpaceDoesNotDoubleNInComposed() {
        typeRomaji("nn")
        _ = press(keyCode: KeyCode.space)
        XCTAssertEqual(handler.state.composedHiragana, "ん")
        XCTAssertEqual(handler.state.pendingRomaji, "")
    }

    func testNNPlusCommaClearsPendingAndSingleN() {
        typeRomaji("nn")
        _ = type(chars: ",", base: ",")
        XCTAssertEqual(handler.state.composedHiragana, "ん、")
        XCTAssertEqual(handler.state.pendingRomaji, "")
    }

    func testNNPlusBracketFlushDoesNotDoubleN() {
        typeRomaji("nn")
        _ = type(chars: "[", base: "[")
        XCTAssertEqual(handler.state.composedHiragana, "ん「")
        XCTAssertEqual(handler.state.pendingRomaji, "")
    }

    func testNNPlusF6CommitsSingleHiraganaN() {
        typeRomaji("nn")
        let (consumed, _) = press(keyCode: KeyCode.f6)
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.inserted.last, "ん")
        XCTAssertFalse(handler.state.isComposing)
    }

    func testEnterWithTrailingNAfterShitenConfirmsPrefixFocusCandidate() {
        typeRomaji("shitenn")
        XCTAssertEqual(handler.state.composedHiragana, "してん")
        let ctx = CandidateContext(
            isVisible: true, selectedRow: 1, selectedText: "視点", isExplicitlySelected: false
        )
        handleAndApply(keyCode: KeyCode.enter, candidate: ctx)
        XCTAssertEqual(client.inserted.last, "視点")
    }
}
