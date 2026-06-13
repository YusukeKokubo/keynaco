import XCTest
@testable import KeynacoCore

final class AzooKeyLcidMapperTests: XCTestCase {
    func testProperNounPlace() {
        let c = AzooKeyLcidMapper.classification(for: 1293)
        XCTAssertEqual(c?.pos, "proper_noun/place")
    }

    func testProperNounPerson() {
        let c = AzooKeyLcidMapper.classification(for: 1289)
        XCTAssertEqual(c?.pos, "proper_noun/person")
    }

    func testNounStem() {
        let c = AzooKeyLcidMapper.classification(for: 1283)
        XCTAssertEqual(c?.pos, "noun")
    }

    func testVerbLcid() {
        XCTAssertEqual(AzooKeyLcidMapper.classification(for: 900)?.pos, "verb")
    }

    func testAdjectiveLcid() {
        XCTAssertEqual(AzooKeyLcidMapper.classification(for: 43)?.pos, "adjective")
    }

    func testParticleLcid() {
        XCTAssertEqual(AzooKeyLcidMapper.classification(for: 148)?.pos, "particle")
    }

    func testAuxiliaryVerbLcid() {
        XCTAssertEqual(AzooKeyLcidMapper.classification(for: 460)?.pos, "verb")
    }

    func testPrefixLcidReturnsNil() {
        XCTAssertNil(AzooKeyLcidMapper.classification(for: 558))
    }

    // MARK: - rank(for:)

    func testRankProperNounPlace() {
        XCTAssertEqual(AzooKeyLcidMapper.rank(for: 1293), .properNoun)
    }

    func testRankNounStem() {
        XCTAssertEqual(AzooKeyLcidMapper.rank(for: 1283), .noun)
    }

    func testRankProperNounBeatsNoun() {
        XCTAssertLessThan(AzooKeyLcidMapper.rank(for: 1293), AzooKeyLcidMapper.rank(for: 1283))
    }

    func testRankVerbFormsShareVerbRank() {
        XCTAssertEqual(AzooKeyLcidMapper.rank(for: 619), .verb)
        XCTAssertEqual(AzooKeyLcidMapper.rank(for: 625), .verb)
    }

    func testRankAdjective() {
        XCTAssertEqual(AzooKeyLcidMapper.rank(for: 43), .adjective)
    }

    func testRankParticle() {
        XCTAssertEqual(AzooKeyLcidMapper.rank(for: 148), .particle)
    }

    func testRankAuxiliary() {
        XCTAssertEqual(AzooKeyLcidMapper.rank(for: 460), .auxiliary)
        XCTAssertLessThan(AzooKeyLcidMapper.rank(for: 148), AzooKeyLcidMapper.rank(for: 460))
    }

    func testRankContentBeatsParticle() {
        XCTAssertLessThan(AzooKeyLcidMapper.rank(for: 1283), AzooKeyLcidMapper.rank(for: 148))
    }

    func testRankPrefixLcidIsUnknown() {
        XCTAssertEqual(AzooKeyLcidMapper.rank(for: 558), .unknown)
    }

    func testRankNilLcidIsUnknown() {
        XCTAssertEqual(AzooKeyLcidMapper.rank(for: nil), .unknown)
    }

    func testLcidRankFromLcidDelegatesToMapper() {
        XCTAssertEqual(LcidRank.from(lcid: 1293), .properNoun)
    }

    func testLcidRankFromPosFallback() {
        XCTAssertEqual(LcidRank.from(pos: "proper_noun/place"), .properNoun)
        XCTAssertEqual(LcidRank.from(pos: "noun"), .noun)
        XCTAssertEqual(LcidRank.from(pos: "adjective"), .adjective)
        XCTAssertEqual(LcidRank.from(pos: "particle"), .particle)
        XCTAssertEqual(LcidRank.from(pos: "verb"), .verb)
        XCTAssertEqual(LcidRank.from(pos: "other/conjunction"), .unknown)
        XCTAssertEqual(LcidRank.from(pos: nil), .unknown)
    }
}
