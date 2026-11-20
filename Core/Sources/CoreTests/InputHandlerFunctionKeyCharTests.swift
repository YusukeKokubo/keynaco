import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

/// NSEvent の機能キー用私用文字（U+F700–U+F8FF）は組成に混ぜない。
/// macOS 更新後、Ctrl+D が修飾なしの Forward Delete（keyCode 117, U+F728）として届き、
/// 組成に混入して `あああ\u{F728}` のように確定されていた。
final class InputHandlerFunctionKeyCharTests: InputHandlerTestCase {

    private let forwardDeleteKeyCode: UInt16 = 117
    private let forwardDeleteChar = "\u{F728}"

    func testForwardDeleteWhileComposingIsSwallowed() {
        typeRomaji("aaa")
        let result = handleAndApply(keyCode: forwardDeleteKeyCode, characters: forwardDeleteChar,
                                    baseCharacters: forwardDeleteChar, modifiers: .function)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(handler.state.composedHiragana, "あああ")
        XCTAssertEqual(client.markedText, "あああ")
        XCTAssertTrue(client.inserted.isEmpty)
    }

    func testForwardDeleteThenEnterCommitsWithoutPrivateUseChar() {
        typeRomaji("aaa")
        for _ in 0..<3 {
            handleAndApply(keyCode: forwardDeleteKeyCode, characters: forwardDeleteChar,
                           baseCharacters: forwardDeleteChar, modifiers: .function)
        }
        press(keyCode: KeyCode.enter)
        XCTAssertEqual(client.inserted, ["あああ"])
    }

    func testForwardDeleteWithPendingRomajiKeepsPending() {
        typeRomaji("ak")
        handleAndApply(keyCode: forwardDeleteKeyCode, characters: forwardDeleteChar,
                       baseCharacters: forwardDeleteChar, modifiers: .function)
        XCTAssertEqual(handler.state.composedHiragana, "あ")
        XCTAssertEqual(handler.state.pendingRomaji, "k")
    }

    func testForwardDeleteWithoutCompositionPassesThrough() {
        let result = handleAndApply(keyCode: forwardDeleteKeyCode, characters: forwardDeleteChar,
                                    baseCharacters: forwardDeleteChar, modifiers: .function)
        XCTAssertFalse(result.consumed, "組成外ならホストの前方削除に任せる")
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertFalse(handler.state.isComposing)
    }

    func testHomeEndWhileComposingAreSwallowed() {
        typeRomaji("ka")
        for (code, ch) in [(UInt16(115), "\u{F729}"), (UInt16(119), "\u{F72B}")] {
            handleAndApply(keyCode: code, characters: ch, baseCharacters: ch, modifiers: .function)
        }
        XCTAssertEqual(handler.state.composedHiragana, "か")
    }
}
