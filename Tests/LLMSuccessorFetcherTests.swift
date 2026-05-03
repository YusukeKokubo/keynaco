import XCTest
@testable import keynaco

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
        let p = LLMSuccessorFetcher.buildPrompt(words: ["報告", "資料", "会議"])
        XCTAssertTrue(p.contains("報告、資料、会議"))
        XCTAssertTrue(p.contains("に続く語"))
        let p2 = LLMSuccessorFetcher.buildPrompt(words: ["東京"])
        XCTAssertTrue(p2.contains("東京"))
        XCTAssertTrue(p2.contains("に続く語"))
    }
}
