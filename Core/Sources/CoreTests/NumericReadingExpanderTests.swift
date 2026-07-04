import XCTest
@testable import KeynacoCore

final class NumericReadingExpanderTests: XCTestCase {

    func test6GatuExpandsToRokugatsu() {
        XCTAssertEqual(NumericReadingExpander.engineReading(for: "6がつ"), "ろくがつ")
    }

    func test7GatuExpandsToShichigatsu() {
        XCTAssertEqual(NumericReadingExpander.engineReading(for: "7がつ"), "しちがつ")
    }

    func test7GetsuNormalizesToShichigatsu() {
        XCTAssertEqual(NumericReadingExpander.engineReading(for: "7げつ"), "しちがつ")
    }

    func test12GatuExpandsToJunigatsu() {
        XCTAssertEqual(NumericReadingExpander.engineReading(for: "12がつ"), "じゅうにがつ")
    }

    func testInvalidMonthReturnsNil() {
        XCTAssertNil(NumericReadingExpander.engineReading(for: "13がつ"))
        XCTAssertNil(NumericReadingExpander.engineReading(for: "0がつ"))
    }

    func testPartialSuffixReturnsNil() {
        XCTAssertNil(NumericReadingExpander.engineReading(for: "7が"))
    }

    func test7NitiExpandsToNanoka() {
        XCTAssertEqual(NumericReadingExpander.engineReading(for: "7にち"), "なのか")
    }

    func test1NitiExpandsToTsuitachi() {
        XCTAssertEqual(NumericReadingExpander.engineReading(for: "1にち"), "ついたち")
    }

    func test2026NenExpands() {
        XCTAssertEqual(NumericReadingExpander.engineReading(for: "2026ねん"), "にせんにじゅうろくねん")
    }

    func testPlainReadingReturnsNil() {
        XCTAssertNil(NumericReadingExpander.engineReading(for: "かんじ"))
        XCTAssertNil(NumericReadingExpander.engineReading(for: "1234"))
    }
}
