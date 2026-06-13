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
}
