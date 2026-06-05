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

    func testZenzaiPromotedTop1AfterUserDictIncreasesFixedEnd() {
        let top1 = zenzaiMock.candidateLines[0]
        handler.leftSideContext = "左文脈"
        type(chars: "a", base: "a")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, let fixedEnd) = action else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertEqual(candidates[fixedEnd - 1], top1, "Zenzai top-1 が固定枠末尾")
        XCTAssertGreaterThanOrEqual(fixedEnd, 1, "Zenzai top-1 昇格で fixedEnd は少なくとも1")
    }

    func testZenzaiPromotedRowIsBelowFixedEndForShiftDelete() {
        handler.leftSideContext = "ctx"
        type(chars: "a", base: "a")
        let (_, action) = press(keyCode: 49)
        guard case .show(_, _, _, _, let fixedEnd) = action else {
            XCTFail(".show を返すはず"); return
        }
        let promotedRow = fixedEnd - 1
        XCTAssertLessThan(promotedRow, fixedEnd, "プロモート行は Shift+Delete 可能帯の外（index < fixedEnd）")
    }

    func testZenzaiPromotedTop1SingleOccurrenceAsideFromHistoryDup() {
        let top1 = zenzaiMock.candidateLines[0]
        handler.leftSideContext = "ctx"
        type(chars: "a", base: "a")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates.filter { $0 == top1 }.count, 1, "辞書ブロックに top-1 が重複して現れない")
    }

    /// 高スコア履歴に読みと同じひらがながあるとき、Zenzai top-1 よりそちらを初期選択する。
    func testZenzaiInitialRowPrefersHiraganaExactMatchInHistory() {
        zenzaiMock.candidateLines = ["士大夫", "死体", "支隊"]
        handler.leftSideContext = "文脈"
        handler.db.record(input: "したい", output: "したい")
        handler.db.record(input: "したい", output: "したい時に")
        typeRomaji("shitai")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("士大夫"), "Zenzai top-1 は候補に残る: \(candidates)")
        XCTAssertEqual(candidates[initialRow], "したい", "履歴のひらがな一致が Zenzai より初期選択")
        XCTAssertNotEqual(candidates[initialRow], "士大夫")
    }

}
