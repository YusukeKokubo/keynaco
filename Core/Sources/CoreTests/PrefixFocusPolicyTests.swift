import XCTest
@testable import KeynacoCore

final class PrefixFocusPolicyTests: XCTestCase {

    func testMinimumMorae_byRank() {
        XCTAssertEqual(PrefixFocusPolicy.minimumMorae(for: .noun), 2)
        XCTAssertEqual(PrefixFocusPolicy.minimumMorae(for: .properNoun), 2)
        XCTAssertEqual(PrefixFocusPolicy.minimumMorae(for: .verb), 3)
        XCTAssertEqual(PrefixFocusPolicy.minimumMorae(for: .adjective), 3)
        XCTAssertEqual(PrefixFocusPolicy.minimumMorae(for: .unknown), 5)
        XCTAssertNil(PrefixFocusPolicy.minimumMorae(for: .particle))
        XCTAssertNil(PrefixFocusPolicy.minimumMorae(for: .auxiliary))
    }

    func testRank_fromPos() {
        XCTAssertEqual(PrefixFocusPolicy.rank(fromPos: "noun"), .noun)
        XCTAssertEqual(PrefixFocusPolicy.rank(fromPos: "proper_noun/place"), .properNoun)
        XCTAssertEqual(PrefixFocusPolicy.rank(fromPos: "adjective"), .adjective)
        XCTAssertEqual(PrefixFocusPolicy.rank(fromPos: "verb"), .verb)
        XCTAssertEqual(PrefixFocusPolicy.rank(fromPos: "particle"), .particle)
        XCTAssertEqual(PrefixFocusPolicy.rank(fromPos: "other"), .unknown)
    }

    func testHistoryEntry_dropsIneligiblePrefix() {
        let entry = HistoryEntry(output: "食べる", score: .prefix(10))
        let kept = entry.applyingPrefixFocusGate { _ in false }
        XCTAssertNil(kept)

        let both = HistoryEntry(output: "食べる", score: .both(exact: 20, prefix: 10))
        let exactOnly = both.applyingPrefixFocusGate { _ in false }
        XCTAssertEqual(exactOnly?.exactScore, 20)
        XCTAssertNil(exactOnly?.prefixScore)
    }

    func testHistoryEntry_keepsEligiblePrefix() {
        let entry = HistoryEntry(output: "食べる", score: .prefix(10))
        let kept = entry.applyingPrefixFocusGate { _ in true }
        XCTAssertEqual(kept?.prefixScore, 10)
    }
}
