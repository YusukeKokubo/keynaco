import XCTest
@testable import KeynacoCore

// MARK: - モッククライアント

final class MockTextClient: TextInputClient {
    private(set) var inserted: [String] = []
    private(set) var markedText: String = ""
    private(set) var setMarkedTextCallCount = 0
    var mockedSelectedRange: NSRange = .init(location: 0, length: 0)
    private(set) var lastReplacementRange: NSRange? = nil

    func insertText(_ text: String) { inserted.append(text); markedText = "" }
    func setMarkedText(_ text: String, selectionRange: NSRange) {
        setMarkedTextCallCount += 1
        markedText = text
    }
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
        let result = handler.handle(keyCode: 0, characters: chars, baseCharacters: base ?? chars,
                                    modifiers: modifiers, candidate: ctx, client: client)
        if result.consumed { applyCandidateAction(result.candidateAction) } // 本番は未消費でも apply するが、ここでは不変なら省略可
        return result
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
        let result = handler.handle(keyCode: keyCode, characters: nil, baseCharacters: nil,
                                    modifiers: modifiers, candidate: ctx, client: client)
        if result.consumed { applyCandidateAction(result.candidateAction) }
        return result
    }

    func typeRomaji(_ s: String) {
        for c in s { type(chars: String(c), base: String(c)) }
    }

    /// `handler.handle` の直後に `applyCandidateAction` する。`type` / `press` 以外から `handle` を呼ぶテスト用。
    @discardableResult
    func handleAndApply(
        keyCode: UInt16,
        characters: String? = nil,
        baseCharacters: String? = nil,
        modifiers: NSEvent.ModifierFlags = [],
        candidate: CandidateContext? = nil
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        let ctx = candidate ?? handler.candidateSession.makeContext()
        let result = handler.handle(
            keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
            modifiers: modifiers, candidate: ctx, client: client
        )
        if result.consumed { applyCandidateAction(result.candidateAction) }
        return result
    }

    /// `InputController.applyCandidateEffects` の session + marked 部分（ウィンドウなし）。
    @discardableResult
    func applyCandidateAction(_ action: CandidateAction) -> CandidateAction {
        handler.applyCandidateAction(action, client: client)
        return action
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

    // MARK: - アサーションヘルパー

    /// action が .show なら候補リストを返す。そうでなければテストを失敗させて nil を返す。
    @discardableResult
    func candidates(
        in action: CandidateAction, _ msg: String = "",
        file: StaticString = #file, line: UInt = #line
    ) -> [String]? {
        guard let payload = action.showPayload else {
            XCTFail("Expected .show but got \(action). \(msg)", file: file, line: line)
            return nil
        }
        return payload.candidates
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

    func assertCandidatesContain(
        _ action: CandidateAction, _ expected: String...,
        file: StaticString = #file, line: UInt = #line
    ) {
        guard let list = candidates(in: action, file: file, line: line) else { return }
        for e in expected {
            XCTAssertTrue(list.contains(e), "候補に \(e) を含むはず。\(list)", file: file, line: line)
        }
    }

    /// `buildCandidateList` と `withoutAzooKey` → `rebuildCandidateList` の結果が一致すること。
    func assertInjectPathMatchesSync(
        stub: any AzooKeyConverting,
        trigger: CandidateListTrigger = .explicit,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sync = handler.buildCandidateList(trigger: trigger)
        let inject = injectPathAction(stub: stub, trigger: trigger, file: file, line: line)
        assertCandidateActionEqual(sync, inject, file: file, line: line)
    }

    func assertCandidateActionEqual(
        _ lhs: CandidateAction,
        _ rhs: CandidateAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (lhs, rhs) {
        case (.dismiss, .dismiss), (.none, .none):
            return
        case let (.show(l), .show(r)):
            XCTAssertEqual(l.candidates, r.candidates, "candidates", file: file, line: line)
            XCTAssertEqual(l.fixedEnd, r.fixedEnd, "fixedEnd", file: file, line: line)
            XCTAssertEqual(l.azooKeyApiOrder, r.azooKeyApiOrder, "azooKeyApiOrder", file: file, line: line)
            XCTAssertEqual(
                l.initialIsExplicitlySelected,
                r.initialIsExplicitlySelected,
                "initialIsExplicitlySelected",
                file: file,
                line: line
            )
            XCTAssertEqual(l.candidateSources, r.candidateSources, "candidateSources", file: file, line: line)
        default:
            XCTFail("Expected matching actions but got \(lhs) vs \(rhs)", file: file, line: line)
        }
    }

    private func injectPathAction(
        stub: any AzooKeyConverting,
        trigger: CandidateListTrigger,
        file: StaticString,
        line: UInt
    ) -> CandidateAction {
        let (_, pending) = handler.buildCandidateListWithoutAzooKey(trigger: trigger)
        guard let reading = pending else {
            return handler.buildCandidateListWithoutAzooKey(trigger: trigger).action
        }
        let azooKey = stub.requestCandidates(
            hiragana: reading,
            leftSideContext: handler.leftContext.azooKeyValue,
            richCandidates: trigger == .explicit
        )
        return handler.rebuildCandidateList(
            reading: reading,
            azooKeyCandidates: azooKey,
            trigger: trigger
        )
    }
}
