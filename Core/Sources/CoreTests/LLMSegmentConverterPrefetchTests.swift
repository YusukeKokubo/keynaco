import XCTest
@testable import KeynacoCore

@MainActor
final class LLMSegmentConverterPrefetchTests: XCTestCase {

    func testTakePrefetchIfMatching_returnsNilWhenNoCache() {
        let c = LLMSegmentConverter()
        XCTAssertNil(c.takePrefetchIfMatching(hiragana: "あいうえおか"))
    }

    func testTakePrefetchIfMatching_returnsSeededTextAndClears() {
        let c = LLMSegmentConverter()
        c._testing_seedCompletedPrefetch(hiragana: "あいうえおか", text: "青い魚岡")
        XCTAssertEqual(c.takePrefetchIfMatching(hiragana: "あいうえおか"), "青い魚岡")
        XCTAssertNil(c.takePrefetchIfMatching(hiragana: "あいうえおか"))
    }

    func testTakePrefetchIfMatching_wrongHiraganaReturnsNilAndKeepsCacheForCorrectKey() {
        let c = LLMSegmentConverter()
        c._testing_seedCompletedPrefetch(hiragana: "あいうえおか", text: "青い魚岡")
        XCTAssertNil(c.takePrefetchIfMatching(hiragana: "あいうえおき"))
        XCTAssertEqual(c.takePrefetchIfMatching(hiragana: "あいうえおか"), "青い魚岡")
    }

    func testCancelClearsSeededPrefetch() {
        let c = LLMSegmentConverter()
        c._testing_seedCompletedPrefetch(hiragana: "あいうえおか", text: "青い魚岡")
        c.cancel()
        XCTAssertNil(c.takePrefetchIfMatching(hiragana: "あいうえおか"))
    }

    func testSegmentPrefetchMinHiraganaCount_isSix() {
        XCTAssertEqual(LLMSegmentConverter.segmentPrefetchMinHiraganaCount, 6)
    }
}
