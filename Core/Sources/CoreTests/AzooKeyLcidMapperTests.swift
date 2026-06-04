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

    func testVerbLcidReturnsNil() {
        XCTAssertNil(AzooKeyLcidMapper.classification(for: 900))
    }
}
