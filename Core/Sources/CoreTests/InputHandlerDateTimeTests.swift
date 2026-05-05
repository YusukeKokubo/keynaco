import XCTest
@testable import KeynacoCore

final class InputHandlerDateTimeTests: XCTestCase {

    func testKyouReturns4Candidates() {
        let result = InputHandler.generateDateTimeCandidates(for: "きょう")
        XCTAssertEqual(result.count, 4)
        XCTAssertTrue(result[0].hasSuffix("日"), "〇年〇月〇日形式: \(result[0])")
        XCTAssertTrue(result[1].hasSuffix("日"), "〇月〇日形式: \(result[1])")
        XCTAssertTrue(result[2].contains("-"), "ISO形式: \(result[2])")
        XCTAssertTrue(result[3].contains("/"), "スラッシュ形式: \(result[3])")
    }

    func testKinouReturns4Candidates() {
        let result = InputHandler.generateDateTimeCandidates(for: "きのう")
        XCTAssertEqual(result.count, 4)
        XCTAssertTrue(result[0].hasSuffix("日"))
    }

    func testAshitaReturns4Candidates() {
        let result = InputHandler.generateDateTimeCandidates(for: "あした")
        XCTAssertEqual(result.count, 4)
        XCTAssertTrue(result[0].hasSuffix("日"))
    }

    func testAsuReturns4Candidates() {
        let result = InputHandler.generateDateTimeCandidates(for: "あす")
        XCTAssertEqual(result.count, 4)
    }

    func testImaReturns1Candidate() {
        let result = InputHandler.generateDateTimeCandidates(for: "いま")
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].contains(":"), "時刻形式: \(result[0])")
    }

    func testKotoshiReturns2Candidates() {
        let result = InputHandler.generateDateTimeCandidates(for: "ことし")
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].hasSuffix("年"), "〇年形式: \(result[0])")
        XCTAssertFalse(result[1].hasSuffix("年"), "数字のみ: \(result[1])")
    }

    func testKyonenReturns2Candidates() {
        let result = InputHandler.generateDateTimeCandidates(for: "きょねん")
        XCTAssertEqual(result.count, 2)
    }

    func testRainenReturns2Candidates() {
        let result = InputHandler.generateDateTimeCandidates(for: "らいねん")
        XCTAssertEqual(result.count, 2)
    }

    func testKongetsuReturns2Candidates() {
        let result = InputHandler.generateDateTimeCandidates(for: "こんげつ")
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].hasSuffix("月"), "〇年〇月形式: \(result[0])")
        XCTAssertTrue(result[1].hasSuffix("月"), "〇月形式: \(result[1])")
    }

    func testUnknownReadingReturnsEmpty() {
        XCTAssertTrue(InputHandler.generateDateTimeCandidates(for: "あいう").isEmpty)
    }
}
