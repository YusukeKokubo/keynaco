import XCTest
@testable import KeynacoCore

final class KeyDispatchTests: XCTestCase {

    private func input(
        keyCode: UInt16 = 0,
        isBackspace: Bool = false,
        isAsciiMode: Bool = false,
        isBracketMode: Bool = false,
        candidateVisible: Bool = false,
        isComposing: Bool = false,
        ignoreNextModeSwitch: Bool = false
    ) -> KeyDispatchInput {
        KeyDispatchInput(
            keyCode: keyCode,
            isBackspace: isBackspace,
            isAsciiMode: isAsciiMode,
            isBracketMode: isBracketMode,
            candidateVisible: candidateVisible,
            isComposing: isComposing,
            ignoreNextModeSwitch: ignoreNextModeSwitch
        )
    }

    func testBracketModeTakesPriority() {
        let route = KeyDispatch.route(input(
            keyCode: KeyCode.f6,
            isBracketMode: true,
            isComposing: true
        ))
        XCTAssertEqual(route, .bracketMode)
    }

    func testFunctionKeyWhenNotAscii() {
        XCTAssertEqual(KeyDispatch.route(input(keyCode: KeyCode.f7, isComposing: true)), .functionKey)
    }

    func testFunctionKeySkippedInAsciiMode() {
        let route = KeyDispatch.route(input(keyCode: KeyCode.f7, isAsciiMode: true))
        XCTAssertEqual(route, .asciiMode)
    }

    func testModeSwitchWithEchoSuppress() {
        let route = KeyDispatch.route(input(
            keyCode: KeyCode.eisu,
            ignoreNextModeSwitch: true
        ))
        XCTAssertEqual(route, .modeSwitch(suppressEcho: true))
    }

    func testModeSwitchKana() {
        XCTAssertEqual(
            KeyDispatch.route(input(keyCode: KeyCode.kana)),
            .modeSwitch(suppressEcho: false)
        )
    }

    func testAsciiModeRoute() {
        XCTAssertEqual(
            KeyDispatch.route(input(keyCode: KeyCode.space, isAsciiMode: true)),
            .asciiMode
        )
    }

    func testCandidateVisibleOverridesComposeOnly() {
        XCTAssertEqual(
            KeyDispatch.route(input(keyCode: KeyCode.enter, candidateVisible: true)),
            .candidateVisible
        )
        XCTAssertEqual(
            KeyDispatch.route(input(keyCode: KeyCode.backspace, isBackspace: true, candidateVisible: true)),
            .candidateVisible
        )
    }

    func testComposeOnlyWhenCandidateHidden() {
        XCTAssertEqual(
            KeyDispatch.route(input(keyCode: KeyCode.enter, isComposing: true)),
            .composeOnly(.enter)
        )
        XCTAssertEqual(
            KeyDispatch.route(input(keyCode: KeyCode.escape)),
            .composeOnly(.escape)
        )
        XCTAssertEqual(
            KeyDispatch.route(input(keyCode: KeyCode.backspace, isBackspace: true)),
            .composeOnly(.backspace)
        )
    }

    func testNormalInputForLetter() {
        XCTAssertEqual(
            KeyDispatch.route(input(keyCode: 0, isComposing: true)),
            .normalInput
        )
    }

    func testBracketBeatsModeSwitch() {
        XCTAssertEqual(
            KeyDispatch.route(input(keyCode: KeyCode.eisu, isBracketMode: true, ignoreNextModeSwitch: true)),
            .bracketMode
        )
    }
}
