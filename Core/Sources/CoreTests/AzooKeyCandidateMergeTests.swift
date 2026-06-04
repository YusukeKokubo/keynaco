import XCTest
@testable import KeynacoCore

/// `AzooKeyCandidateMerge` の境界選択（エンジン部分候補のみ）の単体テスト。AzooKey 実機不要。
final class AzooKeyCandidateMergeTests: XCTestCase {

    func testDefaultClauseEndPrefersParticleBoundaryOverLongerReadingMatch() {
        let result = AzooKeyConversionResult(
            mainResults: [],
            firstClauseResults: [
                AzooKeyClauseCandidate(text: "わたしは", inputLength: 4),
                AzooKeyClauseCandidate(text: "わたし", inputLength: 3),
            ]
        )
        let end = AzooKeyCandidateMerge.defaultClauseEnd(
            result: result,
            convertTarget: "わたしはがくせい"
        )
        XCTAssertEqual(end, 3, "はの直前で切る")
    }

    func testDefaultClauseEndPrefersHiraganaPartialOverWrongKanjiChunk() {
        let result = AzooKeyConversionResult(
            mainResults: [],
            firstClauseResults: [
                AzooKeyClauseCandidate(text: "今一", inputLength: 4),
                AzooKeyClauseCandidate(text: "こんにち", inputLength: 4),
            ]
        )
        let end = AzooKeyCandidateMerge.defaultClauseEnd(
            result: result,
            convertTarget: "こんにちは"
        )
        XCTAssertEqual(end, 4)
    }

    func testDefaultClauseEndFallsBackToPoliteSuffixWhenNoPartials() {
        let result = AzooKeyConversionResult(
            mainResults: [AzooKeyClauseCandidate(text: "学生です", inputLength: 6)],
            firstClauseResults: []
        )
        let end = AzooKeyCandidateMerge.defaultClauseEnd(
            result: result,
            convertTarget: "がくせいです"
        )
        XCTAssertEqual(end, 4)
    }

    func testClauseEndStrippingDoesNotStripSingleParticle() {
        XCTAssertNil(AzooKeyCandidateMerge.clauseEndStrippingTrailingParticle("あなたは"))
    }

    func testDefaultClauseEndDoesNotSplitAtNiInsideKonnichi() {
        let result = AzooKeyConversionResult(
            mainResults: [],
            firstClauseResults: [
                AzooKeyClauseCandidate(text: "こん", inputLength: 2),
                AzooKeyClauseCandidate(text: "こんにち", inputLength: 4),
            ]
        )
        let end = AzooKeyCandidateMerge.defaultClauseEnd(
            result: result,
            convertTarget: "こんにちは"
        )
        XCTAssertEqual(end, 4, "こん|には ではなく こんにち|は")
    }
}
