import XCTest
@testable import ykey

// MARK: - モッククライアント

final class MockTextClient: TextInputClient {
    private(set) var inserted: [String] = []
    private(set) var markedText: String = ""

    func insertText(_ text: String) { inserted.append(text) }
    func setMarkedText(_ text: String, selectionRange: NSRange) { markedText = text }
    func cursorRect() -> NSRect { .zero }
}

// MARK: - テスト

final class InputHandlerTests: XCTestCase {

    private var handler: InputHandler!
    private var client: MockTextClient!

    override func setUp() {
        super.setUp()
        handler = InputHandler(db: DatabaseManager(inMemory: true))
        client = MockTextClient()
    }

    // MARK: - ユーティリティ

    /// 文字キーを入力する（keyCode は使わない）
    @discardableResult
    private func type(
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

    /// keyCode で特殊キーを押す（Return=36, Escape=53, Space=49, BS=51, 英数=102, かな=104）
    @discardableResult
    private func press(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        candidateVisible: Bool = false,
        selectedRow: Int = 0,
        selectedText: String? = nil
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        let ctx = CandidateContext(isVisible: candidateVisible, selectedRow: selectedRow, selectedText: selectedText)
        return handler.handle(keyCode: keyCode, characters: nil, baseCharacters: nil,
                               modifiers: modifiers, candidate: ctx, client: client)
    }

    // MARK: - ローマ字 → ひらがな変換

    func testTypingKaMarksHiragana() {
        type(chars: "k", base: "k")
        XCTAssertEqual(client.markedText, "k")
        type(chars: "a", base: "a")
        XCTAssertEqual(client.markedText, "か")
    }

    func testTypingSingleVowel() {
        type(chars: "a", base: "a")
        XCTAssertEqual(client.markedText, "あ")
    }

    func testTypingTwoVowelsShowsCandidates() {
        type(chars: "a", base: "a")
        let (consumed, action) = type(chars: "i", base: "i")
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.markedText, "あい")
        guard case .show(let candidates, _) = action else {
            XCTFail("2文字以上で .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("あい"))
    }

    // MARK: - Return で確定

    func testReturnCommitsComposing() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 36)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["あ"])
    }

    func testReturnWhenEmptyPassesThrough() {
        let result = press(keyCode: 36)
        XCTAssertFalse(result.consumed)
        XCTAssertTrue(client.inserted.isEmpty)
    }

    func testReturnWithSelectedCandidateCommitsCandidate() {
        handler.db.insertDict(reading: "あ", candidate: "阿", priority: 0)
        type(chars: "a", base: "a")
        // row > 0 = 明示的に候補を選んだ状態
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 1, selectedText: "阿")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["阿"])
        guard case .dismiss = result.candidateAction else {
            XCTFail("確定後は .dismiss を返すはず"); return
        }
    }

    // MARK: - Escape でリセット

    func testEscapeClearsComposing() {
        type(chars: "k", base: "k")
        XCTAssertEqual(client.markedText, "k")
        let result = press(keyCode: 53)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "")
        guard case .dismiss = result.candidateAction else {
            XCTFail("Escape は .dismiss を返すはず"); return
        }
    }

    func testEscapeWhenEmptyPassesThrough() {
        XCTAssertFalse(press(keyCode: 53).consumed)
    }

    // MARK: - Backspace

    func testBackspaceRemovesPendingRomaji() {
        type(chars: "k", base: "k")
        XCTAssertEqual(client.markedText, "k")
        let result = press(keyCode: 51)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "")
    }

    func testBackspaceRemovesHiragana() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        XCTAssertEqual(client.markedText, "あい")
        let result = press(keyCode: 51)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "あ")
    }

    func testBackspaceWhenEmptyPassesThrough() {
        XCTAssertFalse(press(keyCode: 51).consumed)
    }

    // MARK: - スペースで候補表示

    func testSpaceWithHiraganaShowsCandidates() {
        type(chars: "a", base: "a")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        guard case .show(let candidates, _) = action else {
            XCTFail("スペースで .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("あ"))
    }

    func testSpaceWithNothingPassesThrough() {
        XCTAssertFalse(press(keyCode: 49).consumed)
    }

    func testKatakanaAppearsAtIndexOne() {
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show(let candidates, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates[0], "あい", "先頭はひらがなのはず")
        XCTAssertEqual(candidates[1], "アイ", "2番目はカタカナのはず")
    }

    func testKatakanaInCandidatesWhenSpacePressed() {
        type(chars: "a", base: "a")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        guard case .show(let candidates, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.contains("ア"), "カタカナが候補に含まれるはず")
    }

    func testSpaceDuringCandidatesReturnsSelectNext() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 49, candidateVisible: true, selectedRow: 0)
        XCTAssertTrue(result.consumed)
        guard case .selectNext = result.candidateAction else {
            XCTFail("候補表示中のスペースは .selectNext を返すはず"); return
        }
    }

    // MARK: - ASCII モード（英数キー）

    func testAsciiModeInsertsDirectly() {
        press(keyCode: 102)  // 英数キー
        let result = type(chars: "a", base: "a")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["a"])
        XCTAssertEqual(client.markedText, "")
    }

    func testAsciiModeCommitsComposingFirst() {
        type(chars: "a", base: "a")  // "あ" が未確定
        press(keyCode: 102)          // 英数キーで確定 + ASCII モードへ
        XCTAssertEqual(client.inserted, ["あ"])
    }

    func testEscapeExitsAsciiMode() {
        press(keyCode: 102)   // 英数キー
        press(keyCode: 53)    // Escape → 日本語モードへ
        type(chars: "a", base: "a")
        XCTAssertEqual(client.markedText, "あ")
        XCTAssertTrue(client.inserted.isEmpty)
    }

    // MARK: - Shift + 文字 → 英字を直接挿入

    func testShiftLetterInsertsDirectly() {
        type(chars: "A", base: "a", modifiers: .shift)
        XCTAssertEqual(client.inserted, ["A"])
    }

    func testShiftLetterCommitsComposingFirst() {
        type(chars: "a", base: "a")  // "あ" が未確定
        type(chars: "B", base: "b", modifiers: .shift)
        XCTAssertEqual(client.inserted, ["あ", "B"])
    }

    // MARK: - 句読点入力（特別扱いなし）

    func testPeriodBecomesMarkedText() {
        type(chars: ".", base: ".")
        XCTAssertEqual(client.markedText, ".")
        XCTAssertTrue(client.inserted.isEmpty)
    }

    func testPeriodAppendedToComposition() {
        type(chars: "a", base: "a")
        type(chars: ".", base: ".")
        XCTAssertEqual(client.markedText, "あ.")
        XCTAssertTrue(client.inserted.isEmpty)
    }

    func testPeriodAfterPendingConsonant() {
        type(chars: "k", base: "k")
        type(chars: ".", base: ".")
        // "k" がフラッシュされ "k." がマークドテキストになる
        XCTAssertEqual(client.markedText, "k.")
        XCTAssertTrue(client.inserted.isEmpty)
    }

    // MARK: - commitComposition（deactivateServer 相当）

    func testCommitCompositionFinalizesHiragana() {
        type(chars: "k", base: "k")
        type(chars: "a", base: "a")
        handler.commitComposition(client: client)
        XCTAssertEqual(client.inserted, ["か"])
    }

    func testCommitCompositionConvertsPendingN() {
        type(chars: "k", base: "k")
        type(chars: "a", base: "a")
        type(chars: "n", base: "n")
        handler.commitComposition(client: client)
        XCTAssertEqual(client.inserted, ["かん"])
    }

    func testCommitCompositionWhenEmptyDoesNothing() {
        handler.commitComposition(client: client)
        XCTAssertTrue(client.inserted.isEmpty)
    }

    func testCommitCompositionWithExplicitCandidateCommitsCandidate() {
        handler.db.insertDict(reading: "あ", candidate: "阿", priority: 0)
        type(chars: "a", base: "a")
        let ctx = CandidateContext(isVisible: true, selectedRow: 1, selectedText: "阿")
        handler.commitComposition(client: client, candidate: ctx)
        XCTAssertEqual(client.inserted, ["阿"])
    }

    func testCommitCompositionWithRowZeroCommitsHiragana() {
        type(chars: "a", base: "a")
        let ctx = CandidateContext(isVisible: true, selectedRow: 0, selectedText: "あ")
        handler.commitComposition(client: client, candidate: ctx)
        XCTAssertEqual(client.inserted, ["あ"])
    }
}
