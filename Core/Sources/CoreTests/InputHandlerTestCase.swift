import XCTest
@testable import KeynacoCore

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
        let db = DatabaseManager(inMemory: true)
        db.seedHiraganaPreferredWords()
        handler = InputHandler(db: db)
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

    /// content_bigram 予測テスト用: 学習行（count >= 2）と `lastConfirmedContentWordOutput` をセットする。
    func seedContentBigramPrediction(prev: String, input: String, output: String) {
        recordFetchableContentBigram(prev: prev, input: input, output: output)
        handler.lastConfirmedContentWordOutput = prev
    }

    /// `fetchContentBigram` が返す最低 count（2）を満たすよう記録する。
    func recordFetchableContentBigram(prev: String, input: String, output: String) {
        handler.db.recordContentBigram(prev: prev, input: input, output: output)
        handler.db.recordContentBigram(prev: prev, input: input, output: output)
    }

    /// 既定の `setUp` 後に AzooKey スタブ等へ差し替える。
    func setUpWithConverter(_ converter: any AzooKeyConverting) {
        let db = DatabaseManager(inMemory: true)
        db.seedHiraganaPreferredWords()
        handler = InputHandler(db: db, azooKeyConverter: converter)
        client = MockTextClient()
    }

    /// ローマ字入力のあと1キー（既定 Space）を送る。
    @discardableResult
    func typeAndPress(_ romaji: String, keyCode: UInt16 = KeyCode.space) -> (Bool, CandidateAction) {
        typeRomaji(romaji)
        return press(keyCode: keyCode)
    }

    /// ローマ字入力後、候補表示中に `selectedText` を付けて Enter で確定。
    @discardableResult
    func confirmWithSelection(_ romaji: String, selectedText: String) -> (Bool, CandidateAction) {
        typeRomaji(romaji)
        return press(keyCode: KeyCode.enter, candidateVisible: true, selectedText: selectedText)
    }

    /// Space でセグメントモードに入った直後の `SegmentState`（入れなければ nil）。
    func enterSegmentMode(with romaji: String) -> SegmentState? {
        typeRomaji(romaji)
        _ = press(keyCode: KeyCode.space)
        return handler.state.segmentState
    }

    // MARK: - アサーションヘルパー

    /// action が .show なら候補リストを返す。そうでなければテストを失敗させて nil を返す。
    @discardableResult
    func candidates(
        in action: CandidateAction, _ msg: String = "",
        file: StaticString = #file, line: UInt = #line
    ) -> [String]? {
        guard case .show(let candidates, _, _, _, _) = action else {
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

    func assertMarkedText(
        _ expected: String, _ msg: String = "",
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertEqual(client.markedText, expected, msg, file: file, line: line)
    }

    /// 直近の `insertText` 1件を検証する。
    func assertInserted(
        _ expected: String, _ msg: String = "",
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertEqual(client.inserted.last, expected, msg, file: file, line: line)
    }

    func assertSuccessorCandidateActive(
        _ candidateVisible: Bool,
        _ expected: Bool,
        _ msg: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let active = candidateVisible
            && handler.state.composedHiragana.isEmpty
            && !handler.isBracketMode
            && !handler.state.isSegmentMode
        XCTAssertEqual(active, expected, msg, file: file, line: line)
    }

    func assertSegmentMode(
        _ expected: Bool, _ msg: String = "",
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertEqual(handler.state.isSegmentMode, expected, msg, file: file, line: line)
    }

    func assertCandidatesContain(
        _ action: CandidateAction, _ expected: String...,
        file: StaticString = #file, line: UInt = #line
    ) {
        guard let list = candidates(in: action, file: file, line: line) else { return }
        for e in expected {
            XCTAssertTrue(list.contains(e), "候補に \(e) を含むはず。\(list)", file: file, line: line)
        }
    }

    @discardableResult
    func requireSegmentMode(minSegments: Int = 2, file: StaticString = #file, line: UInt = #line) -> SegmentState? {
        guard handler.state.isSegmentMode, let ss = handler.state.segmentState, ss.segments.count >= minSegments else {
            XCTFail("セグメントモードかつ文節数 >= \(minSegments) を期待", file: file, line: line)
            return nil
        }
        return ss
    }
}
