import XCTest
@testable import KeynacoCore

@MainActor
final class LLMMisconversionCheckerTests: XCTestCase {

    func testBuildPromptEmptyRecentWordsMatchesLegacyPrompt() {
        let text = "サンプル文章です。"
        let prompt = LLMMisconversionChecker.buildPrompt(text: text, recentWords: [])
        let expected = """
        次の日本語テキストに誤変換や不自然な表現があれば、箇所と修正案を指摘してください。
        問題がなければ「OK」とだけ答えてください。
        \(text)
        """
        XCTAssertEqual(prompt, expected)
    }

    func testBuildPromptWithWordsInsertsSectionAndList() {
        let text = "前文の続き"
        let words = ["会議", "資料"]
        let prompt = LLMMisconversionChecker.buildPrompt(text: text, recentWords: words)
        XCTAssertTrue(prompt.hasPrefix("【このユーザーが使う語の例】"))
        XCTAssertTrue(prompt.contains("会議、資料"))
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.firstIndex(of: "【このユーザーが使う語の例】") else {
            XCTFail("見出しが見つからない"); return
        }
        XCTAssertEqual(lines[header + 1], "会議、資料", "見出しの次行は読点区切りの語列")
        XCTAssertEqual(lines[header + 2], "", "語列の次は空行")
        XCTAssertTrue(lines[header + 3].hasPrefix("次の日本語テキストに"))
    }

    func testBuildPromptWithFiveWordsJoinsAll() {
        let words = ["一", "二", "三", "四", "五"]
        let prompt = LLMMisconversionChecker.buildPrompt(text: "x", recentWords: words)
        XCTAssertTrue(prompt.contains("一、二、三、四、五"))
    }
}
