import XCTest
@testable import keynaco
import KeynacoCore

/// アプリバンドル上で Zenzai on の rich 等価性を確認（SPM slow ではモデルなしでスキップされる補完）。
final class AzooKeyRichEquivalenceHostedTests: XCTestCase {

    private static let words = ["かんじ", "にほん", "さくら"]

    func testRichCandidatesEquivalence_zenzaiOn_withLeftContext() throws {
        guard Bundle.main.url(forResource: "ggml-model-Q5_K_M", withExtension: "gguf") != nil else {
            throw XCTSkip("Zenzai model not in app bundle")
        }
        let converter = ZenzaiSettings.makeConverter()
        guard converter.isZenzaiEnabled else {
            throw XCTSkip("Zenzai disabled in settings")
        }
        let ctx = "日本語のテストです"
        for word in Self.words {
            let plain = converter.requestCandidates(
                hiragana: word,
                leftSideContext: ctx,
                richCandidates: false
            )
            let rich = converter.requestCandidates(
                hiragana: word,
                leftSideContext: ctx,
                richCandidates: true
            )
            XCTAssertEqual(
                plain,
                rich,
                "Zenzai on: rich/non-rich should match for \(word)"
            )
        }
    }
}
