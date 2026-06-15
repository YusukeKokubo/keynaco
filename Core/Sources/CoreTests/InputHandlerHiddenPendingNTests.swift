import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

/// `nn` 後の hidden pending `n` が Space / 句読点 / F6 / 括弧で二重「ん」にならないこと。
/// また Enter による候補確定時に hidden pending `n` を trailing romaji として扱わないこと。
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

    // hiddenPendingN のとき Enter は "n" を trailing romaji として扱わず、
    // prefix focus 候補を確定する（"してん" + nn → "視点" Enter で "視点" を確定）
    func testEnterWithHiddenPendingNConfirmsPrefixFocusCandidate() {
        typeRomaji("shitenn")
        XCTAssertTrue(handler.state.hiddenPendingN)
        XCTAssertEqual(handler.state.composedHiragana, "してん")
        let ctx = CandidateContext(
            isVisible: true, selectedRow: 1, selectedText: "視点", isExplicitlySelected: false
        )
        handleAndApply(keyCode: KeyCode.enter, candidate: ctx)
        XCTAssertEqual(client.inserted.last, "視点")
    }
}
