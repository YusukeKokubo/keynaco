import XCTest
@testable import KeynacoCore

/// `inferSegmentBoundaries` の単体テスト。`candidatesForSegment` は最短一致の前提を満たすよう、
/// **短い読みでは長いトークンを返さない**スタブで固定する。
private final class SegmentBoundaryMockAzooKey: AzooKeyConverting, @unchecked Sendable {
    var segmentCandidates: [String: [String]] = [:]

    func requestCandidates(hiragana: String, leftSideContext: String?) -> [String] {
        _ = leftSideContext
        return []
    }

    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        _ = leftSideContext
        return segmentCandidates[reading] ?? []
    }

    func commit(reading: String, text: String) {}

    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])] {
        _ = leftSideContext
        return []
    }
}

final class SegmentBoundaryTests: XCTestCase {

    func testCompoundWordSingleReading() {
        let mock = SegmentBoundaryMockAzooKey()
        mock.segmentCandidates = [
            "き": [],
            "きか": [],
            "きかい": [],
            "きかいが": [],
            "きかいがく": [],
            "きかいがくし": [],
            "きかいがくしゅ": [],
            "きかいがくしゅう": ["機械学習"],
        ]
        let out = LLMSegmentConverter.inferSegmentBoundaries(
            hiragana: "きかいがくしゅう",
            llmText: "機械学習",
            azooKey: mock,
            baselineSegmentReadings: ["きかいがくしゅう"]
        )
        XCTAssertEqual(out?.map(\.reading), ["きかいがくしゅう"])
        XCTAssertEqual(out?.map(\.token), ["機械学習"])
    }

    func testThreeTokensWithParticles() {
        let mock = SegmentBoundaryMockAzooKey()
        mock.segmentCandidates = [
            "き": [], "きか": [], "きかい": [], "きかいが": [], "きかいがく": [], "きかいがくし": [],
            "きかいがくしゅ": [], "きかいがくしゅう": ["機械学習"],
        ]
        let out = LLMSegmentConverter.inferSegmentBoundaries(
            hiragana: "きかいがくしゅうをする",
            llmText: "機械学習をする",
            azooKey: mock,
            baselineSegmentReadings: ["きかいがくしゅう", "を", "する"]
        )
        // `tokenizeByScript` は連続するひらがなを1トークンにまとめるため「を」「する」は「をする」になる
        XCTAssertEqual(out?.map(\.reading), ["きかいがくしゅう", "をする"])
        XCTAssertEqual(out?.map(\.token), ["機械学習", "をする"])
    }

    func testKatakanaWordJudo() {
        let mock = SegmentBoundaryMockAzooKey()
        mock.segmentCandidates = [
            "じ": [], "じゅ": [], "じゅう": [], "じゅうど": [],
            "じゅうどう": ["柔道"],
        ]
        let out = LLMSegmentConverter.inferSegmentBoundaries(
            hiragana: "じゅうどう",
            llmText: "柔道",
            azooKey: mock,
            baselineSegmentReadings: ["じゅうどう"]
        )
        XCTAssertEqual(out?.map(\.reading), ["じゅうどう"])
        XCTAssertEqual(out?.map(\.token), ["柔道"])
    }

    func testAlignmentFailsLengthMismatch() {
        let mock = SegmentBoundaryMockAzooKey()
        mock.segmentCandidates = [
            "きょう": ["今日"],
            "きょうは": ["今日は"],
        ]
        let out = LLMSegmentConverter.inferSegmentBoundaries(
            hiragana: "きょうはいい",
            llmText: "今日はいい天気",
            azooKey: mock,
            baselineSegmentReadings: ["きょう", "はいい"]
        )
        XCTAssertNil(out)
    }

    func testKyouHaSameAsAzooKeyBoundary() {
        let mock = SegmentBoundaryMockAzooKey()
        mock.segmentCandidates = [
            "き": [], "きょ": [], "きょう": ["今日"],
            "は": ["は"],
        ]
        let out = LLMSegmentConverter.inferSegmentBoundaries(
            hiragana: "きょうは",
            llmText: "今日は",
            azooKey: mock,
            baselineSegmentReadings: ["きょう", "は"]
        )
        XCTAssertEqual(out?.map(\.reading), ["きょう", "は"])
        XCTAssertEqual(out?.map(\.token), ["今日", "は"])
    }

    func testBaselineJoinMismatchReturnsNil() {
        let mock = SegmentBoundaryMockAzooKey()
        mock.segmentCandidates = ["あ": ["阿"]]
        let out = LLMSegmentConverter.inferSegmentBoundaries(
            hiragana: "あい",
            llmText: "阿",
            azooKey: mock,
            baselineSegmentReadings: ["あ"]
        )
        XCTAssertNil(out)
    }
}
