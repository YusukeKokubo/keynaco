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
        exactMatchHighHistory: [String] = [],
        highHistory: [String] = [],
        historyOutputSet: Set<String> = [],
        exactMatchHistoryOutputs: Set<String> = [],
        fixedSlot: CandidateFixedSlot = .none,
        addsDefaultFixedHiragana: Bool = false
    ) -> CandidateSectionBuildInput {
        CandidateSectionBuildInput(
            reading: reading,
            hiragana: hiragana,
            katakana: KanaUtils.hiraganaToKatakana(hiragana),
            azooKeyCandidates: azooKeyCandidates,
            userDictRaw: userDictRaw,
            exactMatchHighHistory: exactMatchHighHistory,
            highHistory: highHistory,
            historyOutputSet: historyOutputSet,
            exactMatchHistoryOutputs: exactMatchHistoryOutputs,
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
            exactMatchHighHistory: ["感じ"],
            highHistory: ["漢字", "完治", "幹事"],
            historyOutputSet: ["漢字", "完治", "幹事", "感じ"],
            exactMatchHistoryOutputs: ["感じ"]
        )
        let l = layout(from: input)
        XCTAssertEqual(l.candidates.firstIndex(of: "感じ"), 0, "読み完全一致の履歴は先頭に出る")
        XCTAssertEqual(l.candidates.filter { $0 == "漢字" }.count, 1, "履歴表示済みは辞書と重複しない")
    }

    func testExactMatchHistoryPlacedBeforeAzooKey() {
        let input = baseInput(
            reading: "かんじ",
            hiragana: "かんじ",
            azooKeyCandidates: ["漢字候補", "漢字"],
            exactMatchHighHistory: ["感じ"],
            highHistory: ["漢字"]
        )
        let built = CandidateSectionBuilder.build(input)
        XCTAssertEqual(built.sectionOrder, CandidateLayout.exactMatchFirstSectionOrder)
        let l = layout(from: input)
        XCTAssertLessThan(l.candidates.firstIndex(of: "感じ")!, l.candidates.firstIndex(of: "漢字候補")!)
    }

    func testPrefixOnlyHistoryBeyondSlotsRemainsInAzooKey() {
        let input = baseInput(
            reading: "かんじ",
            hiragana: "かんじ",
            azooKeyCandidates: ["漢字", "感じる"],
            highHistory: ["漢字"],
            historyOutputSet: ["漢字", "感じる"],
            exactMatchHistoryOutputs: []
        )
        let l = layout(from: input)
        XCTAssertTrue(l.candidates.contains("感じる"), "top3 漏れの前方一致履歴は辞書に残す")
        XCTAssertFalse(l.candidates.prefix(l.historyEnd).contains("感じる"))
        XCTAssertEqual(l.candidates.filter { $0 == "漢字" }.count, 1, "履歴表示済みは辞書と重複しない")
    }

    func testPrefixOnlyHistoryInHighSlotsSuppressedFromAzooKey() {
        let input = baseInput(
            reading: "かんじ",
            hiragana: "かんじ",
            azooKeyCandidates: ["漢字", "感じる"],
            highHistory: ["漢字", "感じる"],
            historyOutputSet: ["漢字", "感じる"]
        )
        let l = layout(from: input)
        XCTAssertEqual(l.candidates.filter { $0 == "感じる" }.count, 1, "履歴に載る語は辞書と重複しない")
        XCTAssertTrue(l.candidates.prefix(l.historyEnd).contains("感じる"))
        XCTAssertEqual(l.candidates.filter { $0 == "漢字" }.count, 1)
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

    func testWhileTypingDefaultFixed() {
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
