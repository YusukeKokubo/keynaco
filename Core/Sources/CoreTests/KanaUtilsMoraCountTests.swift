import XCTest
@testable import KeynacoCore

final class KanaUtilsMoraCountTests: XCTestCase {

    func testMoraCount_singleMora() {
        XCTAssertEqual(KanaUtils.moraCount(in: "あ"), 1)
        XCTAssertEqual(KanaUtils.moraCount(in: "っ"), 1)
    }

    func testMoraCount_contractedSyllable() {
        XCTAssertEqual(KanaUtils.moraCount(in: "きょう"), 2)
        XCTAssertEqual(KanaUtils.moraCount(in: "しゃ"), 1)
    }

    func testMoraCount_plainSyllables() {
        XCTAssertEqual(KanaUtils.moraCount(in: "だけんす"), 4)
        XCTAssertEqual(KanaUtils.moraCount(in: "かん"), 2)
    }
}
