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
        azooKeyApiOrder: [String] = [],
        userDictRaw: [String] = [],
        exactMatchHighHistory: [String] = [],
        highHistory: [String] = [],
        historyOutputSet: Set<String> = [],
        exactMatchHistoryOutputs: Set<String> = [],
        fixedSlot: CandidateFixedSlot = .none
    ) -> CandidateSectionBuildInput {
        CandidateSectionBuildInput(
            reading: reading,
            hiragana: hiragana,
            azooKeyCandidates: azooKeyCandidates,
            azooKeyApiOrder: azooKeyApiOrder,
            userDictRaw: userDictRaw,
            exactMatchHighHistory: exactMatchHighHistory,
            highHistory: highHistory,
            historyOutputSet: historyOutputSet,
            exactMatchHistoryOutputs: exactMatchHistoryOutputs,
            fixedSlot: fixedSlot,
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
        XCTAssertEqual(l.candidates, ["Acme", "辞書B"])
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
        XCTAssertEqual(l.candidates, ["辞書A", "辞書B", "の"])
    }

    func testHiraganaPreferredFixedSlot() {
        let input = baseInput(
            reading: "の",
            hiragana: "の",
            fixedSlot: .hiragana
        )
        let l = layout(from: input)
        XCTAssertEqual(l.candidates, ["の", "辞書A", "辞書B"])
        XCTAssertEqual(l.fixedEnd, 1)
    }

    func testExactMatchHistorySortedByZenzaiRank() {
        // 履歴頻度: 漢字(5x) > 幹事(3x) > 感じ(2x)
        // Zenzai 順: 感じ(1位) > 幹事(2位) > 漢字(4位)
        // 期待: Zenzai 順が優先されて 感じ → 幹事 → 漢字
        let input = baseInput(
            reading: "かんじ",
            hiragana: "かんじ",
            azooKeyCandidates: ["感じ", "幹事", "完治", "漢字"],
            azooKeyApiOrder: ["感じ", "幹事", "完治", "漢字"],
            exactMatchHighHistory: ["漢字", "幹事", "感じ"],
            historyOutputSet: ["漢字", "幹事", "感じ"],
            exactMatchHistoryOutputs: ["漢字", "幹事", "感じ"]
        )
        let l = layout(from: input)
        let historySlice = Array(l.candidates.prefix(l.historyEnd))
        XCTAssertEqual(historySlice, ["感じ", "幹事", "漢字"])
    }

    func testExactMatchHistoryNoRankGoesLast() {
        // azooKeyApiOrder にない履歴候補はランクなし → 末尾に落ちる
        let input = baseInput(
            reading: "かんじ",
            hiragana: "かんじ",
            azooKeyCandidates: ["感じ", "漢字"],
            azooKeyApiOrder: ["感じ", "漢字"],
            exactMatchHighHistory: ["幹事", "感じ", "漢字"],
            historyOutputSet: ["幹事", "感じ", "漢字"],
            exactMatchHistoryOutputs: ["幹事", "感じ", "漢字"]
        )
        let l = layout(from: input)
        let historySlice = Array(l.candidates.prefix(l.historyEnd))
        XCTAssertEqual(historySlice.first, "感じ")
        XCTAssertEqual(historySlice.last,  "幹事")
    }

    private func builtSectionsContainKind(
        _ kind: CandidateSection.Kind,
        input: CandidateSectionBuildInput
    ) -> Bool {
        CandidateSectionBuilder.build(input).sections.contains { $0.kind == kind }
    }
}
