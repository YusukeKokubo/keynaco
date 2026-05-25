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

    func testUnknownWithoutReadingReturnsNil() {
        XCTAssertNil(AzooKeyPOSClassifier.classify(output: "設定", reading: "", converter: converter))
    }

    func testPosRetryIsAlwaysFalseWhenClassified() {
        let cases: [(String, String)] = [
            ("しかし", "しかし"), ("設定", "せってい"), ("東京", "とうきょう"),
        ]
        for (output, reading) in cases {
            let c = AzooKeyPOSClassifier.classify(output: output, reading: reading, converter: converter)
            XCTAssertFalse(c?.posRetry ?? false, output)
        }
    }

    func testLemmaIsAlwaysNilWhenClassified() {
        let c = AzooKeyPOSClassifier.classify(output: "設定", reading: "せってい", converter: converter)
        XCTAssertNil(c?.lemma)
    }
}
