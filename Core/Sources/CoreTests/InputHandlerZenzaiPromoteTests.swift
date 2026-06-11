import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

// Zenzai top-1 プロモートのふるまいを検証する。PLAN260506 参照。

private final class ZenzaiPromoteTestMockAzooKey: BaseAzooKeyStub, @unchecked Sendable {
    var candidateLines: [String] = ["表層先頭", "表層2番目"]

    override init() {
        super.init()
        isZenzaiEnabled = true
    }

    override func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        candidateLines
    }
}

final class InputHandlerZenzaiPromoteTests: InputHandlerTestCase {
    private var zenzaiMock: ZenzaiPromoteTestMockAzooKey!

    override func setUp() {
        super.setUp()
        zenzaiMock = ZenzaiPromoteTestMockAzooKey()
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: zenzaiMock)
    }

    func testZenzaiPromotedTop1AtRowZero() {
        let top1 = zenzaiMock.candidateLines[0]
        handler.leftContext = .testing(combined: "左文脈")
        type(chars: "a", base: "a")
        let (_, action) = press(keyCode: 49)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertEqual(payload.candidates[0], top1, "Zenzai top-1 が row 0")
        XCTAssertEqual(handler.candidateSession.zenzaiRow, 0)
    }

    func testZenzaiPromotedRowShiftDeleteDoesNothing() {
        let top1 = zenzaiMock.candidateLines[0]
        handler.leftContext = .testing(combined: "ctx")
        type(chars: "a", base: "a")
        let (_, showAction) = press(keyCode: 49)
        guard let payload = showAction.showPayload,
              let promotedRow = payload.candidates.firstIndex(of: top1) else {
            XCTFail(".show を返すはず"); return
        }
        let ctx = CandidateContext(
            isVisible: true,
            selectedRow: promotedRow,
            selectedText: top1,
            isExplicitlySelected: true,
            historyEnd: payload.historyEnd,
            fixedEnd: payload.fixedEnd
        )
        let (_, action) = handler.handle(
            keyCode: KeyCode.backspace, characters: nil, baseCharacters: nil,
            modifiers: .shift, candidate: ctx, client: client
        )
        guard case .none = action else {
            XCTFail("Zenzai プロモート行の Shift+Delete は .none を返すはず: \(action)"); return
        }
    }

    func testZenzaiPromotedTop1SingleOccurrenceAsideFromHistoryDup() {
        let top1 = zenzaiMock.candidateLines[0]
        handler.leftContext = .testing(combined: "ctx")
        type(chars: "a", base: "a")
        let (_, action) = press(keyCode: 49)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(payload.candidates.filter { $0 == top1 }.count, 1, "辞書ブロックに top-1 が重複して現れない")
    }

    /// 高スコア履歴に読みと同じひらがながあるとき、Zenzai top-1 よりそちらを初期選択する。
    func testZenzaiInitialRowPrefersHiraganaExactMatchInHistory() {
        zenzaiMock.candidateLines = ["士大夫", "死体", "支隊"]
        handler.leftContext = .testing(combined: "文脈")
        handler.db.record(input: "したい", output: "したい")
        handler.db.record(input: "したい", output: "したい時に")
        typeRomaji("shitai")
        let (_, action) = press(keyCode: 49)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertTrue(payload.candidates.contains("士大夫"), "Zenzai top-1 は候補に残る: \(payload.candidates)")
        XCTAssertEqual(payload.candidates[payload.initialRow], "したい", "履歴のひらがな一致が Zenzai より初期選択")
        XCTAssertNotEqual(payload.candidates[payload.initialRow], "士大夫")
    }

}
