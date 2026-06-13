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
}
