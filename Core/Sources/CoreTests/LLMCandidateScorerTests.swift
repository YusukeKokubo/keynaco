import XCTest
@testable import KeynacoCore

@MainActor
final class LLMCandidateScorerTests: XCTestCase {

    func testBuildPromptWithoutExamplesOmitsTendencySection() {
        let prompt = LLMCandidateScorer.buildPrompt(
            context: "ctx",
            reading: "よみ",
            candidates: ["A", "B"],
            examples: []
        )
        XCTAssertFalse(prompt.contains("【このユーザーの変換傾向】"))
        XCTAssertTrue(prompt.hasPrefix("【文脈】"))
    }

    func testBuildPromptWithExamplesInsertsSectionAndBlankLineBeforeContext() {
        let prompt = LLMCandidateScorer.buildPrompt(
            context: "前文",
            reading: "しりょう",
            candidates: ["資料"],
            examples: [("資料", "作成")]
        )
        XCTAssertTrue(prompt.contains("【このユーザーの変換傾向】"))
        XCTAssertTrue(prompt.contains("- 「資料」の後 → 「作成」"))
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let tendencyLine = lines.firstIndex(of: "- 「資料」の後 → 「作成」") else {
            XCTFail("傾向行が見つからない"); return
        }
        XCTAssertEqual(lines[tendencyLine + 1], "", "傾向ブロック直後は空行")
        XCTAssertTrue(lines[tendencyLine + 2].hasPrefix("【文脈】"), "空行の次は【文脈】")
    }

    func testBuildPromptWithFiveExamplesPreservesCandidateBlock() {
        let examples: [(prev: String, next: String)] = [
            ("a", "b"), ("c", "d"), ("e", "f"), ("g", "h"), ("i", "j"),
        ]
        let prompt = LLMCandidateScorer.buildPrompt(
            context: "x",
            reading: "y",
            candidates: ["候補1", "候補2", "候補3"],
            examples: examples
        )
        for (prev, next) in examples {
            XCTAssertTrue(
                prompt.contains("- 「\(prev)」の後 → 「\(next)」"),
                "prev=\(prev) next=\(next)"
            )
        }
        XCTAssertTrue(prompt.contains("1. 候補1"))
        XCTAssertTrue(prompt.contains("2. 候補2"))
        XCTAssertTrue(prompt.contains("3. 候補3"))
        XCTAssertTrue(prompt.contains("「番号:high」「番号:mid」「番号:low」"))
        XCTAssertTrue(prompt.contains("例: 2:high"))
    }

    func testParseChosenIndexWithConfidence_colonHigh() {
        let r = LLMCandidateScorer.parseChosenIndexWithConfidence(from: "2:high", maxCount: 3)!
        XCTAssertEqual(r.index, 1)
        XCTAssertEqual(r.confidence, .high)
    }

    func testParseChosenIndexWithConfidence_spacesAroundColonMid() {
        let r = LLMCandidateScorer.parseChosenIndexWithConfidence(from: "2 : mid", maxCount: 3)!
        XCTAssertEqual(r.index, 1)
        XCTAssertEqual(r.confidence, .mid)
    }

    func testParseChosenIndexWithConfidence_embeddedInSentence() {
        let r = LLMCandidateScorer.parseChosenIndexWithConfidence(from: "答えは 1:low です", maxCount: 2)!
        XCTAssertEqual(r.index, 0)
        XCTAssertEqual(r.confidence, .low)
    }

    func testParseChosenIndexWithConfidence_caseInsensitiveConfidence() {
        let r = LLMCandidateScorer.parseChosenIndexWithConfidence(from: "3:MiD", maxCount: 5)!
        XCTAssertEqual(r.index, 2)
        XCTAssertEqual(r.confidence, .mid)
    }

    func testParseChosenIndexWithConfidence_unknownTokenReturnsNil() {
        XCTAssertNil(LLMCandidateScorer.parseChosenIndexWithConfidence(from: "2:unknown", maxCount: 3))
    }

    func testParseChosenIndexWithConfidence_numberOnlyReturnsNil() {
        XCTAssertNil(LLMCandidateScorer.parseChosenIndexWithConfidence(from: "2", maxCount: 3))
    }

    func testParseChosenIndexWithConfidence_outOfRangeReturnsNil() {
        XCTAssertNil(LLMCandidateScorer.parseChosenIndexWithConfidence(from: "4:high", maxCount: 3))
    }
}
