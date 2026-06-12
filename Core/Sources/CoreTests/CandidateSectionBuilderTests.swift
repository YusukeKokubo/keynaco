import XCTest
@testable import KeynacoCore

final class CandidateSectionBuilderTests: XCTestCase {

    private func layout(from input: CandidateSectionBuildInput) -> CandidateLayout {
        let built = CandidateSectionBuilder.build(input)
        return CandidateLayout(
            sections: built.sections,
            sectionOrder: built.sectionOrder,
            initialRowPolicy: .afterFixed
        )
    }

    private func baseInput(
        reading: String = "あい",
        hiragana: String = "あい",
        azooKeyCandidates: [String] = ["辞書A", "辞書B"],
        userDictRaw: [String] = [],
        highHistory: [String] = [],
        historyOutputSet: Set<String> = [],
        exactMatchHistoryOutputs: Set<String> = [],
        zenzaiPromoted: String? = nil,
        fixedSlot: CandidateFixedSlot = .none,
        addsDefaultFixedHiragana: Bool = false
    ) -> CandidateSectionBuildInput {
        CandidateSectionBuildInput(
            reading: reading,
            hiragana: hiragana,
            katakana: KanaUtils.hiraganaToKatakana(hiragana),
            azooKeyCandidates: azooKeyCandidates,
            userDictRaw: userDictRaw,
            highHistory: highHistory,
            historyOutputSet: historyOutputSet,
            exactMatchHistoryOutputs: exactMatchHistoryOutputs,
            zenzaiPromoted: zenzaiPromoted,
            fixedSlot: fixedSlot,
            addsDefaultFixedHiragana: addsDefaultFixedHiragana,
            numberCandidates: [],
            dateTimeCandidates: []
        )
    }

    func testAzooKeyExcludedWhenInHistory() {
        let input = baseInput(
            azooKeyCandidates: ["Acme", "辞書B"],
            userDictRaw: ["Acme"],
            historyOutputSet: ["Acme"]
        )
        let l = layout(from: input)
        XCTAssertEqual(l.candidates, ["Acme", "辞書B", "アイ"])
        XCTAssertEqual(l.candidates.filter { $0 == "Acme" }.count, 1)
    }

    func testExactMatchHistoryNotSuppressedFromAzooKeyWhenBeyondTopSlots() {
        let input = baseInput(
            reading: "かんじ",
            hiragana: "かんじ",
            azooKeyCandidates: ["漢字", "感じ", "完治"],
            highHistory: ["漢字", "完治", "幹事"],
            historyOutputSet: ["漢字", "完治", "幹事", "感じ"],
            exactMatchHistoryOutputs: ["感じ"]
        )
        let l = layout(from: input)
        XCTAssertTrue(l.candidates.contains("感じ"), "読み完全一致の履歴は辞書から除外しない")
        XCTAssertEqual(l.candidates.filter { $0 == "漢字" }.count, 1, "履歴表示済みは辞書と重複しない")
    }

    func testPrefixOnlyHistoryStillSuppressedFromAzooKey() {
        let input = baseInput(
            reading: "かんじ",
            hiragana: "かんじ",
            azooKeyCandidates: ["漢字", "感じる"],
            highHistory: ["漢字"],
            historyOutputSet: ["漢字", "感じる"],
            exactMatchHistoryOutputs: ["漢字"]
        )
        let l = layout(from: input)
        XCTAssertFalse(l.candidates.contains("感じる"), "前方一致のみの履歴は辞書から除外する")
    }

    func testZenzaiTop1NotDuplicatedInAzooKey() {
        let input = baseInput(
            azooKeyCandidates: ["Zen先頭", "辞書B"],
            zenzaiPromoted: "Zen先頭"
        )
        let l = layout(from: input)
        XCTAssertEqual(l.candidates.filter { $0 == "Zen先頭" }.count, 1)
        XCTAssertEqual(l.candidates[0], "Zen先頭")
    }

    func testHiraganaPreferredWithHiraganaInHistorySkipsFixedSlot() {
        let input = baseInput(
            reading: "の",
            hiragana: "の",
            highHistory: ["の"],
            historyOutputSet: ["の"],
            fixedSlot: .none
        )
        let l = layout(from: input)
        XCTAssertFalse(builtSectionsContainKind(.fixedHiragana, input: input))
        XCTAssertEqual(l.candidates, ["の", "辞書A", "辞書B", "ノ"])
    }

    func testWhileTypingZenzaiFirstWithDefaultFixedHiragana() {
        let input = baseInput(
            azooKeyCandidates: ["Zen先頭", "辞書B"],
            zenzaiPromoted: "Zen先頭",
            addsDefaultFixedHiragana: true
        )
        let built = CandidateSectionBuilder.build(input)
        XCTAssertEqual(built.sectionOrder, CandidateLayout.zenzaiFirstSectionOrder)
        let l = layout(from: input)
        XCTAssertEqual(l.candidates, ["Zen先頭", "あい", "辞書B", "アイ"])
    }

    func testWhileTypingDefaultFixedWithoutZenzai() {
        let input = baseInput(addsDefaultFixedHiragana: true)
        let built = CandidateSectionBuilder.build(input)
        XCTAssertEqual(built.sectionOrder, CandidateLayout.defaultSectionOrder)
        let l = layout(from: input)
        XCTAssertEqual(l.candidates, ["あい", "辞書A", "辞書B", "アイ"])
    }

    func testHiraganaPreferredFixedSlot() {
        let input = baseInput(
            reading: "の",
            hiragana: "の",
            fixedSlot: .hiragana
        )
        let l = layout(from: input)
        XCTAssertEqual(l.candidates, ["の", "辞書A", "辞書B", "ノ"])
        XCTAssertEqual(l.fixedEnd, 1)
    }

    private func builtSectionsContainKind(
        _ kind: CandidateSection.Kind,
        input: CandidateSectionBuildInput
    ) -> Bool {
        CandidateSectionBuilder.build(input).sections.contains { $0.kind == kind }
    }
}
