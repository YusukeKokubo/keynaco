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

    /// ri- + n + Enter: 候補選択操作なしの Enter は row 0 を commit する（WYSIWYG）。
    /// pending "n" は捨てられる — 保持したい場合は Escape → 再打鍵で対応する。
    /// 修正前は `.hidden` フォールバックで finalizedText="りーん" が commit され、
    /// row 0 に見えていた候補（例: リーナー）と食い違って penalized ループが発生していた。
    func testPendingNEnterCommitsRow0() {
        setUpWithConverter(SnapStub(["リー"]))
        typeRomaji("ri-")
        XCTAssertTrue(handler.candidateSession.isVisible, "りー で whileTyping 候補が visible")
        XCTAssertEqual(handler.candidateSession.selectedText, "リー", "row 0 は stub の 'リー'")

        _ = type(chars: "n", base: "n")
        XCTAssertEqual(handler.state.composedHiragana, "りー")
        XCTAssertEqual(handler.state.pendingRomaji, "n")
        XCTAssertEqual(client.markedText, "りーn", "pending n は marked に見える")
        XCTAssertTrue(handler.candidateSession.isVisible, "n 打鍵後も candidate visible 維持")
        XCTAssertFalse(handler.candidateSession.isExplicitlySelected, "候補選択操作なし")

        _ = handler.doConfirmSelection(candidate: handler.candidateSession.makeContext(), client: client)
        XCTAssertEqual(client.inserted.last, "リー", "row 0 の候補を commit（pending n は捨てる）")
    }
}
