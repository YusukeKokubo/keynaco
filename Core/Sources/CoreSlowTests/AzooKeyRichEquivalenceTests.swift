import XCTest
@testable import KeynacoCore

/// Phase 3: `richCandidates` true/false の候補リスト等価性（Option A vs B の判断用）。
final class AzooKeyRichEquivalenceTests: XCTestCase {

    private static let words: [String] = [
        "かんじ", "にほん", "とうきょう", "さくら", "なつ",
        "はる", "あき", "ふゆ", "かぜ", "みず",
        "つき", "ほし", "やま", "かわ", "うみ",
        "とり", "はな", "いぬ", "ねこ", "くるま",
    ]

    private static let leftContext = "日本語のテストです"

    func testRichCandidatesEquivalence_zenzaiOff_noContext() {
        let converter = AzooKeyConverter(zenzaiEnabled: false)
        let mismatches = compareRichEquivalence(
            converter: converter,
            leftContext: nil,
            label: "Zenzai=off, no context"
        )
        XCTAssertTrue(
            mismatches.isEmpty,
            "rich true/false should match:\n\(mismatches.joined(separator: "\n"))"
        )
    }

    func testRichCandidatesEquivalence_zenzaiOff_withLeftContext() {
        let converter = AzooKeyConverter(zenzaiEnabled: false)
        let mismatches = compareRichEquivalence(
            converter: converter,
            leftContext: Self.leftContext,
            label: "Zenzai=off, left context"
        )
        XCTAssertTrue(
            mismatches.isEmpty,
            "rich true/false should match:\n\(mismatches.joined(separator: "\n"))"
        )
    }

    func testRichCandidatesEquivalence_zenzaiOn_withLeftContext() throws {
        guard Bundle.main.url(forResource: "ggml-model-Q5_K_M", withExtension: "gguf") != nil else {
            throw XCTSkip("Zenzai model not in test bundle")
        }
        let converter = AzooKeyConverter(zenzaiEnabled: true)
        let mismatches = compareRichEquivalence(
            converter: converter,
            leftContext: Self.leftContext,
            label: "Zenzai=on, left context"
        )
        if !mismatches.isEmpty {
            print("Zenzai=on rich equivalence mismatches (Option B candidate):\n\(mismatches.joined(separator: "\n"))")
        }
        // Zenzai on では rich が候補を変える可能性があるため情報出力のみ（fail しない）
    }

    private func compareRichEquivalence(
        converter: AzooKeyConverter,
        leftContext: String?,
        label: String
    ) -> [String] {
        var mismatches: [String] = []
        for word in Self.words {
            let plain = converter.requestCandidates(
                hiragana: word,
                leftSideContext: leftContext,
                richCandidates: false
            )
            let rich = converter.requestCandidates(
                hiragana: word,
                leftSideContext: leftContext,
                richCandidates: true
            )
            if plain != rich {
                mismatches.append(
                    "[\(label)] \(word): plain=\(plain.prefix(3)) rich=\(rich.prefix(3))"
                )
            }
        }
        return mismatches
    }
}
