import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

// composedHiragana / leftSideContext が変わらない場合に requestCandidates が再呼び出しされないことを確認する。
// キャッシュ本体は `AzooKeyConverter.candidateCache`（Mock も同キーで模倣）。

final class MockAzooKeyConverter: AzooKeyConverting, @unchecked Sendable {
    private(set) var requestCount = 0
    private(set) var lastLeftContext: String?
    private var cache: [String: [String]] = [:]

    private func cacheKey(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> String {
        let ctx = leftSideContext ?? ""
        return richCandidates ? "\(hiragana)|\(ctx)|rich" : "\(hiragana)|\(ctx)"
    }

    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        lastLeftContext = leftSideContext
        let key = cacheKey(hiragana: hiragana, leftSideContext: leftSideContext, richCandidates: richCandidates)
        if let hit = cache[key] { return hit }
        requestCount += 1
        let result = ["テスト"]
        cache[key] = result
        return result
    }

    func peekCachedCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> AzooKeyCachePeek? {
        let key = cacheKey(hiragana: hiragana, leftSideContext: leftSideContext, richCandidates: richCandidates)
        guard let hit = cache[key] else { return nil }
        return AzooKeyCachePeek(candidates: hit, match: .exact)
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

        handler.leftContext = .testing(combined: "前文テスト")
        _ = handler.buildCandidateList(trigger: .explicit)
        XCTAssertEqual(mock.requestCount, 2, "左文脈が変われば同じ読みでも AzooKey を再呼びするはず")
        XCTAssertEqual(mock.lastLeftContext, "前文テスト")
    }
}
