import XCTest
@testable import KeynacoCore

final class LLMSuccessorFetcherTests: XCTestCase {

    func testSplitAndFilterLinesSkipsEmptyAndDuplicatesAndCapsAtFive() {
        let raw = """

        資料

        資料
        きかく
        えいご
        かいぎ
        ほうこく
        追加
        """
        let lines = LLMSuccessorFetcher.splitAndFilterLines(raw)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[0], "資料")
        XCTAssertTrue(lines.contains("きかく"))
        XCTAssertFalse(lines.contains("追加"))
    }

    func testSplitAndFilterLinesExcludesDigitsOnlyAndAsciiHelloAndSymbolsOnly() {
        XCTAssertEqual(LLMSuccessorFetcher.splitAndFilterLines("123"), [])
        XCTAssertEqual(LLMSuccessorFetcher.splitAndFilterLines("１２３"), [])
        XCTAssertEqual(LLMSuccessorFetcher.splitAndFilterLines("hello"), [])
        XCTAssertEqual(LLMSuccessorFetcher.splitAndFilterLines("・・・"), [])
    }

    func testSplitAndFilterLinesKeepsJapaneseSurfaceForms() {
        XCTAssertEqual(LLMSuccessorFetcher.splitAndFilterLines("資料"), ["資料"])
        XCTAssertEqual(LLMSuccessorFetcher.splitAndFilterLines("コーヒー"), ["コーヒー"])
        XCTAssertEqual(LLMSuccessorFetcher.splitAndFilterLines("しりょう"), ["しりょう"])
        XCTAssertEqual(LLMSuccessorFetcher.splitAndFilterLines("1回"), ["1回"])
    }

    func testBuildPromptJoinsContextPhrase() {
        let p = LLMSuccessorFetcher.buildPrompt(
            words: ["報告", "資料", "会議"], documentContextPrefix: "", examples: [])
        XCTAssertTrue(p.contains("報告、資料、会議"))
        XCTAssertTrue(p.contains("に続く語"))
        XCTAssertFalse(p.contains("よく使う語"))
        let p2 = LLMSuccessorFetcher.buildPrompt(words: ["東京"], documentContextPrefix: "", examples: [])
        XCTAssertTrue(p2.contains("東京"))
        XCTAssertTrue(p2.contains("に続く語"))
        XCTAssertFalse(p2.contains("よく使う語"))
    }

    func testBuildPromptIncludesDocumentContextWhenNonEmpty() {
        let p = LLMSuccessorFetcher.buildPrompt(
            words: ["資料"], documentContextPrefix: "先週の会議では", examples: [])
        XCTAssertTrue(p.hasPrefix("【文脈】先週の会議では"))
        XCTAssertTrue(p.contains("「資料」に続く語"))
    }

    func testBuildPromptIncludesTendencyWhenExamplesNonEmpty() {
        let examples: [(prev: String, next: String)] = [
            (prev: "会議", next: "資料"),
            (prev: "会議", next: "議事録"),
        ]
        let p = LLMSuccessorFetcher.buildPrompt(
            words: ["報告", "資料", "会議"], documentContextPrefix: "", examples: examples)
        XCTAssertTrue(p.contains("よく使う語"))
        XCTAssertTrue(p.contains("【このユーザーが「会議」の後によく使う語】"))
        XCTAssertTrue(p.contains("資料、議事録"))
        XCTAssertTrue(p.contains("報告、資料、会議"))
        XCTAssertTrue(p.contains("に続く語"))
    }

    func testBuildPromptMismatchedPrevStillRendersBothSections() {
        let examples: [(prev: String, next: String)] = [(prev: "単独語", next: "候補")]
        let p = LLMSuccessorFetcher.buildPrompt(
            words: ["報告", "資料", "会議"], documentContextPrefix: "", examples: examples)
        XCTAssertTrue(p.contains("【このユーザーが「単独語」の後によく使う語】"))
        XCTAssertTrue(p.contains("候補"))
        XCTAssertTrue(p.contains("報告、資料、会議"))
    }
}
