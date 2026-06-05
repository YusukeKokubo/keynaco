import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

// composedHiragana が変わらない場合に requestCandidates が再呼び出しされないことを確認するテスト

final class MockAzooKeyConverter: AzooKeyConverting, @unchecked Sendable {
    private(set) var requestCount = 0
    private(set) var lastLeftContext: String?

    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = hiragana
        _ = richCandidates
        lastLeftContext = leftSideContext
        requestCount += 1
        return ["テスト"]
    }

    func commit(reading: String, text: String) { _ = (reading, text) }
}

final class AzooKeyCacheTests: XCTestCase {

    var mock: MockAzooKeyConverter!
    var handler: InputHandler!
    var client: MockTextClient!

    override func setUp() {
        super.setUp()
        InputHandler.isAsciiMode = false
        mock = MockAzooKeyConverter()
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: mock)
        client = MockTextClient()
    }

    private func postHandle(_ result: (consumed: Bool, candidateAction: CandidateAction)) {
        guard result.consumed else { return }
        handler.applyCandidateAction(result.candidateAction, client: client)
    }

    func press(keyCode: UInt16, candidateVisible: Bool = false) {
        let ctx = CandidateContext(isVisible: candidateVisible, selectedRow: 0, selectedText: nil)
        postHandle(handler.handle(keyCode: keyCode, characters: nil, baseCharacters: nil,
                                  modifiers: [], candidate: ctx, client: client))
    }

    func type(chars: String) {
        let ctx = CandidateContext(isVisible: false, selectedRow: 0, selectedText: nil)
        postHandle(handler.handle(keyCode: 0, characters: chars, baseCharacters: chars,
                                  modifiers: [], candidate: ctx, client: client))
    }

    // MARK: - AzooKey 呼び出し回数

    func testAzooKeyCalledOncePerBuildCandidateListOnSpace() {
        // Space で buildCandidateList を明示的にトリガーする
        type(chars: "k")
        type(chars: "a")
        type(chars: "i")  // composedHiragana = "かい"
        XCTAssertEqual(mock.requestCount, 1, "whileTyping の buildCandidateList で1回呼ばれるはず")
    }

    func testAzooKeyNotCalledAgainWhenHiraganaUnchanged() {
        // 候補ウィンドウ表示中に ↑↓ でナビゲートしても composedHiragana は変わらない
        // → AzooKey は追加で呼ばれないはず
        type(chars: "k")
        type(chars: "a")
        type(chars: "i")  // composedHiragana = "かい" → buildCandidateList(whileTyping) → AzooKey 1回
        let countAfterInput = mock.requestCount

        // ↓ キー（候補ウィンドウ表示中扱い）
        let ctx = CandidateContext(isVisible: true, selectedRow: 0, selectedText: nil)
        postHandle(handler.handle(keyCode: KeyCode.downArrow, characters: nil, baseCharacters: nil,
                                  modifiers: [], candidate: ctx, client: client))
        XCTAssertEqual(mock.requestCount, countAfterInput,
                       "↓ キーで composedHiragana が変わらなければ AzooKey を再呼びしないはず")
    }

    func testAzooKeyNotCalledAgainForSamePreviousHiragana() {
        // "かい" → バックスペース → "か" → "い" で "かい" に戻るとき、AzooKey を再呼びしない
        type(chars: "k"); type(chars: "a"); type(chars: "i")  // "かい" → AzooKey("かい") 1回
        let countAfterKai = mock.requestCount

        press(keyCode: KeyCode.backspace)  // "か" に → AzooKey("か") 1回（変化あり）
        let countAfterBackspace = mock.requestCount

        type(chars: "i")  // 再び "かい" → D 実装後はキャッシュヒット → AzooKey 呼ばない
        XCTAssertEqual(mock.requestCount, countAfterBackspace,
                       "同じ composedHiragana「かい」に戻るとき AzooKey を再呼びしないはず")
    }

    func testAzooKeyCalledAgainWhenHiraganaChanges() {
        // "あ" → "あい" と入力したとき AzooKey は composedHiragana が変わるたびに呼ばれる
        type(chars: "k"); type(chars: "a")  // "か" → AzooKey("か") 1回
        let countAfterKa = mock.requestCount

        type(chars: "i")  // "かい" → AzooKey("かい") → 1回追加
        XCTAssertGreaterThan(mock.requestCount, countAfterKa,
                             "composedHiragana が変わったので AzooKey が再呼びされるはず")
    }

    func testAzooKeyCalledAgainWhenLeftContextChangesWithSameHiragana() {
        type(chars: "k")
        type(chars: "a")
        type(chars: "i")
        XCTAssertEqual(mock.requestCount, 1)

        handler.leftSideContext = "前文テスト"
        _ = handler.buildCandidateList(trigger: .explicit)
        XCTAssertEqual(mock.requestCount, 2, "左文脈が変われば同じ読みでも AzooKey を再呼びするはず")
        XCTAssertEqual(mock.lastLeftContext, "前文テスト")
    }
}
