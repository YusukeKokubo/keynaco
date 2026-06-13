import XCTest
@testable import KeynacoCore

final class AzooKeyPOSClassifierTests: XCTestCase {
    private let converter = AzooKeyConverter()

    func testConjunctionIsFiltered() {
        let c = AzooKeyPOSClassifier.classify(output: "しかし", reading: "しかし", converter: converter)
        XCTAssertEqual(c?.pos, "other/conjunction")
    }

    func testInterjectionIsFiltered() {
        let c = AzooKeyPOSClassifier.classify(output: "ええっと", reading: "ええっと", converter: converter)
        XCTAssertEqual(c?.pos, "other/interjection")
    }

    func testNounFromDictionary() {
        let c = AzooKeyPOSClassifier.classify(output: "設定", reading: "せってい", converter: converter)
        XCTAssertEqual(c?.pos, "noun")
    }

    func testProperNounPlaceFromDictionary() {
        let c = AzooKeyPOSClassifier.classify(output: "東京", reading: "とうきょう", converter: converter)
        XCTAssertEqual(c?.pos, "proper_noun/place")
    }

    func testVerbFromDictionary() {
        let c = AzooKeyPOSClassifier.classify(output: "調べる", reading: "しらべる", converter: converter)
        XCTAssertEqual(c?.pos, "verb")
        XCTAssertEqual(c?.lcid, 619)
    }

    func testAdjectiveFromDictionary() {
        let c = AzooKeyPOSClassifier.classify(output: "難しい", reading: "むずかしい", converter: converter)
        XCTAssertEqual(c?.pos, "adjective")
        XCTAssertEqual(c?.lcid, 43)
    }

    func testUnknownWithoutReadingReturnsNil() {
        XCTAssertNil(AzooKeyPOSClassifier.classify(output: "設定", reading: "", converter: converter))
    }
}
