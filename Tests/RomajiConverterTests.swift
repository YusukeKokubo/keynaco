import XCTest
@testable import ykey

final class RomajiConverterTests: XCTestCase {

    private func assertConvert(_ input: String, converted: String, pending: String,
                                file: StaticString = #file, line: UInt = #line) {
        let result = RomajiConverter.convert(input)
        XCTAssertEqual(result.converted, converted, "converted mismatch for \"\(input)\"", file: file, line: line)
        XCTAssertEqual(result.pending, pending, "pending mismatch for \"\(input)\"", file: file, line: line)
    }

    // MARK: - 基本的な変換

    func testVowels() {
        assertConvert("a", converted: "あ", pending: "")
        assertConvert("i", converted: "い", pending: "")
        assertConvert("u", converted: "う", pending: "")
        assertConvert("e", converted: "え", pending: "")
        assertConvert("o", converted: "お", pending: "")
    }

    func testBasicConsonantVowel() {
        assertConvert("ka", converted: "か", pending: "")
        assertConvert("shi", converted: "し", pending: "")
        assertConvert("tsu", converted: "つ", pending: "")
        assertConvert("fu", converted: "ふ", pending: "")
        assertConvert("chi", converted: "ち", pending: "")
    }

    func testMultipleCharacters() {
        assertConvert("kaigi", converted: "かいぎ", pending: "")
        assertConvert("sushi", converted: "すし", pending: "")
        assertConvert("toukyou", converted: "とうきょう", pending: "")
        assertConvert("tokyo", converted: "ときょ", pending: "")
        assertConvert("arigatou", converted: "ありがとう", pending: "")
    }

    // MARK: - pending（未確定）

    func testPendingConsonant() {
        assertConvert("k", converted: "", pending: "k")
        assertConvert("sh", converted: "", pending: "sh")
        assertConvert("ch", converted: "", pending: "ch")
        assertConvert("ts", converted: "", pending: "ts")
    }

    func testPartialInput() {
        assertConvert("kaig", converted: "かい", pending: "g")
        assertConvert("sush", converted: "す", pending: "sh")
    }

    // MARK: - っ（促音）

    func testDoubleConsonant() {
        assertConvert("kka", converted: "っか", pending: "")
        assertConvert("tta", converted: "った", pending: "")
        assertConvert("ssh", converted: "っ", pending: "sh")
        assertConvert("sakka", converted: "さっか", pending: "")
        assertConvert("motto", converted: "もっと", pending: "")
    }

    // MARK: - ん

    func testNBeforeConsonant() {
        assertConvert("nk", converted: "ん", pending: "k")
        assertConvert("nm", converted: "ん", pending: "m")
        assertConvert("kantan", converted: "かんた", pending: "n")
    }

    func testNBeforeVowel() {
        assertConvert("na", converted: "な", pending: "")
        assertConvert("ni", converted: "に", pending: "")
        assertConvert("kana", converted: "かな", pending: "")
    }

    func testNN() {
        assertConvert("nn", converted: "ん", pending: "n")
        assertConvert("kanna", converted: "かんな", pending: "")
    }

    func testNAlone() {
        assertConvert("n", converted: "", pending: "n")
        assertConvert("kan", converted: "か", pending: "n")
    }

    // MARK: - 拗音

    func testYouon() {
        assertConvert("kya", converted: "きゃ", pending: "")
        assertConvert("sho", converted: "しょ", pending: "")
        assertConvert("chu", converted: "ちゅ", pending: "")
        assertConvert("nya", converted: "にゃ", pending: "")
        assertConvert("ryo", converted: "りょ", pending: "")
    }

    // MARK: - forceFinalize

    func testForceFinalizeN() {
        XCTAssertEqual(RomajiConverter.forceFinalize("n"), "ん")
        XCTAssertEqual(RomajiConverter.forceFinalize(""), "")
    }

    func testForceFinalizeOther() {
        XCTAssertEqual(RomajiConverter.forceFinalize("k"), "k")
        XCTAssertEqual(RomajiConverter.forceFinalize("sh"), "sh")
    }

    // MARK: - エッジケース

    func testSpacePassesThrough() {
        // スペースはローマ字テーブルに存在しないため converted にそのまま出力される。
        // InputController はスペースを addRomaji に渡す前に捕捉しなければならない。
        // （渡すと composedHiragana にスペースが混入する）
        assertConvert(" ", converted: " ", pending: "")
    }

    func testLongSentence() {
        assertConvert("konnichiwa", converted: "こんにちわ", pending: "")
    }

    func testHyphenToLongVowel() {
        assertConvert("ra-men", converted: "らーめ", pending: "n")
    }
}
