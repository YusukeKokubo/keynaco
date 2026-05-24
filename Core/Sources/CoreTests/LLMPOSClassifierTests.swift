import XCTest
@testable import KeynacoCore

final class LLMPOSClassifierTests: XCTestCase {

    // MARK: - normalizeTag

    func testMarkdownStripping() {
        XCTAssertEqual(LLMPOSClassifier.normalizeTag("**noun/common**"), "noun/common")
        XCTAssertEqual(LLMPOSClassifier.normalizeTag("`verb/te`"), "verb/te")
        XCTAssertEqual(LLMPOSClassifier.normalizeTag("_proper_noun/place_"), "proper_noun/place")
    }

    func testConfidenceParsing() {
        XCTAssertEqual(LLMPOSClassifier.normalizeTag("proper_noun/place:high"), "proper_noun/place:high")
        XCTAssertEqual(LLMPOSClassifier.normalizeTag("noun/suru:mid"),          "noun/suru:mid")
        XCTAssertEqual(LLMPOSClassifier.normalizeTag("verb/te:low"),            "verb/te:low")
    }

    func testExplanatoryResponseExtraction() {
        // 説明文が混入しても known タグを抽出できる
        XCTAssertEqual(LLMPOSClassifier.normalizeTag("田中 → proper_noun/person:mid"),               "proper_noun/person:mid")
        XCTAssertEqual(LLMPOSClassifier.normalizeTag("「山田太郎」の品詞タグは proper_noun/person です。"), "proper_noun/person")
    }

    func testCategoryIgnoresConfidence() {
        // proper_noun は subcategory まで保持
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("proper_noun/place:high"),  "proper_noun/place")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("noun/suru:mid"),           "noun")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("verb/ta:low"),             "verb")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("adjective/na:high"),       "adjective")
    }

    // MARK: - categoryFromTag

    func testCategoryFromTagHierarchical() {
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("noun/common"),          "noun")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("noun/suru"),            "noun")
        // proper_noun は subcategory を pos にそのまま格納する
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("proper_noun/place"),    "proper_noun/place")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("proper_noun/person"),   "proper_noun/person")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("proper_noun/org"),      "proper_noun/org")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("proper_noun/product"),  "proper_noun/product")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("proper_noun/work"),     "proper_noun/work")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("proper_noun/product:high"), "proper_noun/product")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("proper_noun"),          "proper_noun")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("verb/te"),              "verb")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("verb/ta"),              "verb")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("verb/dict"),            "verb")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("adjective/i"),          "adjective")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("adjective/na"),         "adjective")
        // particle/* は pos="other"、other/* は subcategory を pos に保持
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("particle/case"),        "other")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("particle/topic"),       "other")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("particle/aux"),         "other")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("other/conjunction"),    "other/conjunction")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("other/interjection"),   "other/interjection")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("other/clause"),         "other/clause")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("other/unknown"),        "other/unknown")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("other"),                "other")
    }

    func testCategoryFromTagJapanese() {
        // 日本語応答は subcategory なしの proper_noun にフォールバック
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("固有名詞"),             "proper_noun")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("名詞"),                 "noun")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("動詞"),                 "verb")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("形容詞"),               "adjective")
        XCTAssertEqual(LLMPOSClassifier.categoryFromTag("助詞"),                 "other")
    }

    // MARK: - needsRetry

    func testNeedsRetry() {
        XCTAssertFalse(LLMPOSClassifier.needsRetry(posTag: "proper_noun/place:high"))
        XCTAssertFalse(LLMPOSClassifier.needsRetry(posTag: "noun/suru:mid"))
        XCTAssertTrue(LLMPOSClassifier.needsRetry(posTag: "noun/common:low"))
        XCTAssertTrue(LLMPOSClassifier.needsRetry(posTag: "proper_noun/place"))  // confidence なし
        XCTAssertTrue(LLMPOSClassifier.needsRetry(posTag: "verb/te:confidence")) // 不正トークン
    }

    // MARK: - parsePOSString（後方互換）

    func testParsePOSStringBackcompat() {
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("noun"),         "noun")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("proper_noun"),  "proper_noun")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("verb"),         "verb")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("adjective"),    "adjective")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("other"),        "other")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("**noun/suru**"),"noun")
    }
}
