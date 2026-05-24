import XCTest
@testable import KeynacoCore

final class ContentBigramTests: XCTestCase {

    func testRecordAndFetchContentBigram() {
        let db = DatabaseManager(inMemory: true)
        db.recordContentBigram(prev: "東京", input: "あめ", output: "雨")
        db.recordContentBigram(prev: "東京", input: "あめ", output: "雨")
        db.recordContentBigram(prev: "東京", input: "あめんぼ", output: "雨")

        let results = db.fetchContentBigram(prev: "東京", reading: "あめ")
        XCTAssertTrue(results.contains("雨"))
    }

    func testFetchContentBigramRequiresCountAtLeastTwo() {
        let db = DatabaseManager(inMemory: true)
        db.recordContentBigram(prev: "東京", input: "あめ", output: "雨")
        XCTAssertTrue(db.fetchContentBigram(prev: "東京", reading: "あめ").isEmpty)
    }

    func testRecordContentBigramSkipsEmptyPrev() {
        let db = DatabaseManager(inMemory: true)
        db.recordContentBigram(prev: "", input: "あめ", output: "雨")
        XCTAssertTrue(db.fetchContentBigram(prev: "", reading: "あ").isEmpty)
    }

    func testLemmatizeForPrevVerb() {
        // NLTagger(.lemma) は日本語動詞の基本形を返さない環境があるため、辞書形はそのまま通す。
        XCTAssertEqual(lemmatizeForPrev("行く", pos: "verb"), "行く")
        XCTAssertEqual(lemmatizeForPrev("東京", pos: "noun"), "東京")
        XCTAssertEqual(lemmatizeForPrev("東京", pos: "proper_noun/place"), "東京")
    }

    func testContentWordForPrevPrefersLemma() {
        let classification = POSCommitSequencer.Classification(
            pos: "verb", posTag: "verb:high", posRetry: false, lemma: "行く"
        )
        XCTAssertEqual(contentWordForPrev(output: "行った", classification: classification), "行く")
    }

    func testContentWordForPrevFallsBackToSurfaceWhenLemmaMissing() {
        let classification = POSCommitSequencer.Classification(
            pos: "verb", posTag: "verb:high", posRetry: false, lemma: nil
        )
        XCTAssertEqual(contentWordForPrev(output: "行った", classification: classification), "行った")
    }

    func testContentWordForPrevReturnsSurfaceForNoun() {
        let classification = POSCommitSequencer.Classification(
            pos: "noun", posTag: "noun:high", posRetry: false, lemma: nil
        )
        XCTAssertEqual(contentWordForPrev(output: "東京", classification: classification), "東京")
    }
}
