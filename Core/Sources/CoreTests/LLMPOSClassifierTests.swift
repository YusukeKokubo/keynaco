import XCTest
@testable import KeynacoCore

final class LLMPOSClassifierTests: XCTestCase {

    func testNounVariants() {
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("noun"), "noun")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("名詞"), "noun")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("**noun**"), "noun")
    }

    func testProperNounVariants() {
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("proper_noun"), "proper_noun")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("固有名詞"), "proper_noun")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("固有名詞（東京など）"), "proper_noun")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("**proper_noun**"), "proper_noun")
    }

    func testMarkdownStripping() {
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("`verb`"), "verb")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("_adjective_"), "adjective")
    }

    func testVerbVariants() {
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("verb"), "verb")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("動詞"), "verb")
    }

    func testAdjectiveVariants() {
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("adjective"), "adjective")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("形容詞"), "adjective")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("副詞"), "adjective")
    }

    func testOtherFallback() {
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("other"), "other")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("助詞"), "other")
        XCTAssertEqual(LLMPOSClassifier.parsePOSString("unknown"), "other")
    }
}
