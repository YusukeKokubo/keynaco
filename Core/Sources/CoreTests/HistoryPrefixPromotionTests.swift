import XCTest
@testable import KeynacoCore

final class HistoryPrefixPromotionTests: XCTestCase {

    func testQualifiesWhenScoreHighEnoughAndRatioMet() {
        XCTAssertTrue(HistoryPrefixPromotion.qualifies(prefixScore: 93, bestExactScore: 9))
    }

    func testRejectsWhenBelowMinScore() {
        XCTAssertFalse(HistoryPrefixPromotion.qualifies(prefixScore: 19, bestExactScore: 0))
    }

    func testRejectsWhenRatioNotMet() {
        XCTAssertFalse(HistoryPrefixPromotion.qualifies(prefixScore: 25, bestExactScore: 20))
    }

    func testQualifiesWhenNoExactMatch() {
        XCTAssertTrue(HistoryPrefixPromotion.qualifies(prefixScore: 25, bestExactScore: 0))
    }

    func testPromotedItemsPreservesOrder() {
        let promoted = HistoryPrefixPromotion.promotedItems(
            prefixHistory: ["情報", "状態", "低"],
            prefixScores: ["情報": 100, "状態": 30, "低": 5],
            bestExactScore: 9
        )
        XCTAssertEqual(promoted, ["情報", "状態"])
    }
}
