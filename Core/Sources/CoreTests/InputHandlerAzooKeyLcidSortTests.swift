import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

final class InputHandlerAzooKeyLcidSortTests: XCTestCase {
    func testSortAzooKeyCandidatesByLcidRankStableWithinSameRank() {
        let input = ["調べて", "調べる", "が"]
        let lcidByText = ["調べて": 625, "調べる": 619, "が": 148]
        let sorted = InputHandler.sortAzooKeyCandidatesByLcidRank(input, lcidByText: lcidByText)
        XCTAssertEqual(sorted, ["調べて", "調べる", "が"])
    }

    func testSortAzooKeyCandidatesByLcidRankContentBeforeParticle() {
        let input = ["が", "表示", "漢字"]
        let lcidByText = ["が": 148, "表示": 1283, "漢字": 1283]
        let sorted = InputHandler.sortAzooKeyCandidatesByLcidRank(input, lcidByText: lcidByText)
        XCTAssertEqual(sorted, ["表示", "漢字", "が"])
    }

    func testSortAzooKeyCandidatesByLcidRankEmptyMapPreservesOrder() {
        let input = ["B", "A", "C"]
        XCTAssertEqual(
            InputHandler.sortAzooKeyCandidatesByLcidRank(input, lcidByText: [:]),
            input
        )
    }

    func testZenzaiPromotedUsesPreSortFirstNotLcidSort() {
        let stub = LcidSortZenzaiStub()
        var handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: stub)
        handler.leftContext = .testing(combined: "ctx")
        handler.state.composedHiragana = "あ"
        handler.state.pendingRomaji = ""
        let action = handler.buildCandidateList(trigger: .explicit)
        guard let payload = action.showPayload else {
            XCTFail("expected .show"); return
        }
        XCTAssertEqual(payload.candidates[0], "が", "Zenzai top-1 はソート前 first")
        XCTAssertEqual(payload.candidates.filter { $0 == "が" }.count, 1)
        XCTAssertEqual(
            payload.candidates.filter { $0 == "表示" || $0 == "漢字" },
            ["表示", "漢字"],
            "辞書セクションは lcid ソート後の順序"
        )
    }
}

private final class LcidSortZenzaiStub: BaseAzooKeyStub, @unchecked Sendable {
    override init() {
        super.init()
        isZenzaiEnabled = true
    }

    override func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = (hiragana, leftSideContext, richCandidates)
        return ["が", "表示", "漢字"]
    }

    override func primaryLcidByText(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool
    ) -> [String: Int] {
        _ = (hiragana, leftSideContext, richCandidates)
        return ["が": 148, "表示": 1283, "漢字": 1283]
    }
}
