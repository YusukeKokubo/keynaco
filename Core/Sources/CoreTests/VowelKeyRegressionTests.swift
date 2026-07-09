import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

final class WhileTypingPendingRomajiTests: InputHandlerTestCase {
    /// 子音 pending 中も候補窓は維持され、marked text には未変換ローマ字尾が出る。
    /// commit（Enter）時は `finalizedText` を確定するので marked と一致する（子音は forceFinalize しないため）。
    func testConsonantKeyKeepsCandidatesAndShowsPending() {
        let stub = SnapStub(["漢字", "感じ"])
        setUpWithConverter(stub)
        handler.deferAzooKeyWhileTyping = true
        handler.db.record(input: "あい", output: "愛")

        typeRomaji("ai")
        XCTAssertTrue(handler.candidateSession.isVisible)

        _ = type(chars: "s", base: "s")
        XCTAssertTrue(handler.candidateSession.isVisible, "子音でも候補窓は維持される")
        XCTAssertEqual(handler.state.composedHiragana, "あい")
        XCTAssertEqual(handler.state.pendingRomaji, "s")
        XCTAssertEqual(client.markedText, "あいs", "pending 尾も marked に出す")
    }

    /// ri- + n: pending "n" 中の Enter は marked "りーn" と commit "りーん" が食い違わない
    /// （n → ん の forceFinalize は標準 IME 挙動として理解可能）。
    /// 修正前は passive candidate 表示中に marked が "りー" に潰れ、Enter で "りーん" が commit されて WYSIWYG が破綻しとった。
    func testPendingNEnterCommitsFinalizedReading() {
        let stub = SnapStub(["リー"])
        setUpWithConverter(stub)
        handler.deferAzooKeyWhileTyping = true
        handler.db.record(input: "りーなー", output: "リーナー")

        typeRomaji("ri-")
        _ = type(chars: "n", base: "n")

        XCTAssertEqual(handler.state.composedHiragana, "りー")
        XCTAssertEqual(handler.state.pendingRomaji, "n")
        XCTAssertEqual(client.markedText, "りーn", "pending n は marked に見える")

        _ = handler.doConfirmSelection(candidate: handler.candidateSession.makeContext(), client: client)
        XCTAssertEqual(client.inserted.last, "りーん", "Enter は finalizedText を確定する（n → ん）")
    }
}
