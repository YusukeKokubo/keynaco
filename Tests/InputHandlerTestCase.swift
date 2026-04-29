import XCTest
@testable import keynaco

// MARK: - モッククライアント

final class MockTextClient: TextInputClient {
    private(set) var inserted: [String] = []
    private(set) var markedText: String = ""
    var mockedSelectedRange: NSRange = .init(location: 0, length: 0)
    private(set) var lastReplacementRange: NSRange? = nil

    func insertText(_ text: String) { inserted.append(text); markedText = "" }
    func setMarkedText(_ text: String, selectionRange: NSRange) { markedText = text }
    func selectedRange() -> NSRange { mockedSelectedRange }
    func setMarkedText(_ text: String, selectionRange: NSRange, replacementRange: NSRange) {
        lastReplacementRange = replacementRange
        mockedSelectedRange = NSRange(location: text.count, length: 0)
        setMarkedText(text, selectionRange: selectionRange)
    }
    func cursorRect() -> NSRect { .zero }
}

// MARK: - 共有基底クラス

class InputHandlerTestCase: XCTestCase {

    var handler: InputHandler!
    var client: MockTextClient!

    override func setUp() {
        super.setUp()
        InputHandler.isAsciiMode = false
        handler = InputHandler(db: DatabaseManager(inMemory: true))
        client = MockTextClient()
    }

    // MARK: - ユーティリティ

    @discardableResult
    func type(
        chars: String,
        base: String? = nil,
        modifiers: NSEvent.ModifierFlags = [],
        candidateVisible: Bool = false,
        selectedRow: Int = 0,
        selectedText: String? = nil
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        let ctx = CandidateContext(isVisible: candidateVisible, selectedRow: selectedRow, selectedText: selectedText)
        return handler.handle(keyCode: 0, characters: chars, baseCharacters: base ?? chars,
                               modifiers: modifiers, candidate: ctx, client: client)
    }

    @discardableResult
    func press(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        candidateVisible: Bool = false,
        selectedRow: Int = 0,
        selectedText: String? = nil,
        isExplicitlySelected: Bool = false
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        let ctx = CandidateContext(isVisible: candidateVisible, selectedRow: selectedRow, selectedText: selectedText, isExplicitlySelected: isExplicitlySelected)
        return handler.handle(keyCode: keyCode, characters: nil, baseCharacters: nil,
                               modifiers: modifiers, candidate: ctx, client: client)
    }

    func typeRomaji(_ s: String) {
        for c in s { type(chars: String(c), base: String(c)) }
    }

    // MARK: - アサーションヘルパー

    /// action が .show なら候補リストを返す。そうでなければテストを失敗させて nil を返す。
    @discardableResult
    func candidates(
        in action: CandidateAction, _ msg: String = "",
        file: StaticString = #file, line: UInt = #line
    ) -> [String]? {
        guard case .show(let candidates, _, _, _) = action else {
            XCTFail("Expected .show but got \(action). \(msg)", file: file, line: line)
            return nil
        }
        return candidates
    }

    func assertDismiss(
        _ action: CandidateAction, _ msg: String = "",
        file: StaticString = #file, line: UInt = #line
    ) {
        if case .dismiss = action { return }
        XCTFail("Expected .dismiss but got \(action). \(msg)", file: file, line: line)
    }
}
