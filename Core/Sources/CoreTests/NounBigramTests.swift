import XCTest
@testable import KeynacoCore

final class NounBigramTests: XCTestCase {

    func testRecordAndFetchNounBigram() {
        let db = DatabaseManager(inMemory: true)
        db.recordNounBigram(prev: "東京", input: "あめ", output: "雨")
        db.recordNounBigram(prev: "東京", input: "あめんぼ", output: "雨")

        let results = db.fetchNounBigram(prev: "東京", reading: "あめ")
        XCTAssertTrue(results.contains("雨"))
    }

    func testFetchNounBigramTop() {
        let db = DatabaseManager(inMemory: true)
        db.recordNounBigram(prev: "東京", input: "あめ", output: "雨")
        db.recordNounBigram(prev: "東京", input: "かいしゃ", output: "会社")
        db.recordNounBigram(prev: "東京", input: "かいしゃ", output: "会社")
        db.recordNounBigram(prev: "東京", input: "かいしゃ", output: "会社")

        let top = db.fetchNounBigramTop(prev: "東京", limit: 2)
        XCTAssertEqual(top.first, "会社")
        XCTAssertTrue(top.contains("雨"))
    }

    func testRecordNounBigramSkipsEmptyPrev() {
        let db = DatabaseManager(inMemory: true)
        db.recordNounBigram(prev: "", input: "あめ", output: "雨")
        XCTAssertTrue(db.fetchNounBigramTop(prev: "").isEmpty)
    }
}
