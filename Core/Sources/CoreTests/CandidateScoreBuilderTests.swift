import XCTest
@testable import KeynacoCore

final class CandidateScoreBuilderTests: XCTestCase {

    private func build(
        exact: [String] = [],
        exactScores: [String: Double] = [:],
        prefix: [String] = [],
        prefixScores: [String: Double] = [:],
        userExact: [String] = [],
        userPrefix: [String] = [],
        azooKey: [String] = [],
        azooOrder: [String] = []
    ) -> [ScoredCandidate] {
        CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            exactMatchHighHistory: exact,
            highHistory: prefix,
            exactMatchScores: exactScores,
            prefixHistoryScores: prefixScores,
            userDictExact: userExact,
            userDictPrefix: userPrefix,
            azooKeyCandidates: azooKey,
            azooKeyApiOrder: azooOrder
        ))
    }

    func testHighScorePrefixRanksAboveLowExact() {
        let scored = build(
            exact: ["上"],
            exactScores: ["上": 9],
            prefix: ["情報共有"],
            prefixScores: ["情報共有": 93],
            azooKey: ["情", "条"]
        )
        XCTAssertEqual(scored.map(\.text), ["情報共有", "情", "上", "条"])
        XCTAssertEqual(scored[0].source, .historyPrefix)
        XCTAssertEqual(scored[2].source, .historyExact)
    }

    func testUserDictExactScoreBetweenHistoryAndAzooKey() {
        let scored = build(
            exact: ["低"],
            exactScores: ["低": 9],
            userExact: ["UD語"],
            azooKey: ["辞書A"]
        )
        XCTAssertEqual(scored.map(\.text), ["UD語", "辞書A", "低"])
        XCTAssertEqual(scored[0].score, CandidateScoreBuilder.userDictExactScore)
        XCTAssertEqual(scored[1].score, CandidateScoreBuilder.azooKeyScore(rank: 0))
    }

    func testDedupKeepsHigherScoreSource() {
        let scored = build(
            exact: ["漢字"],
            exactScores: ["漢字": 12],
            prefix: ["漢字"],
            prefixScores: ["漢字": 40],
            azooKey: ["漢字", "感じ"]
        )
        XCTAssertEqual(scored.filter { $0.text == "漢字" }.count, 1)
        XCTAssertEqual(scored.first?.text, "漢字")
        XCTAssertEqual(scored.first?.source, .historyPrefix)
        XCTAssertEqual(scored.first?.score, 40)
    }

    func testHistorySuppressesAzooKeyDuplicate() {
        let scored = build(
            prefix: ["漢字"],
            prefixScores: ["漢字": 5],
            azooKey: ["漢字", "感じ"]
        )
        XCTAssertEqual(scored.map(\.text), ["漢字", "感じ"])
    }

    func testAzooKeyScoreDecaysWithRank() {
        XCTAssertEqual(CandidateScoreBuilder.azooKeyScore(rank: 0), 10, accuracy: 0.001)
        XCTAssertEqual(CandidateScoreBuilder.azooKeyScore(rank: 9), 1, accuracy: 0.001)
    }

    func testExactHistoryTieBreakUsesZenzaiRank() {
        let scored = build(
            exact: ["漢字", "幹事", "感じ"],
            exactScores: ["漢字": 5, "幹事": 5, "感じ": 5],
            azooOrder: ["感じ", "幹事", "完治", "漢字"]
        )
        XCTAssertEqual(scored.map(\.text), ["感じ", "幹事", "漢字"])
    }

    func testBelowCutoffHistoryExcluded() {
        let scored = build(
            exact: ["哀"],
            exactScores: ["哀": 0.4],
            azooKey: ["愛"]
        )
        XCTAssertEqual(scored.map(\.text), ["愛"])
    }
}

final class CandidateScoredLayoutTests: XCTestCase {

    func testHistoryBlockBeforeDictionaryBlock() {
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            exactMatchHighHistory: ["上"],
            highHistory: ["情報共有"],
            exactMatchScores: ["上": 9],
            prefixHistoryScores: ["情報共有": 93],
            userDictExact: [],
            userDictPrefix: [],
            azooKeyCandidates: ["情"],
            azooKeyApiOrder: []
        ))
        let layout = CandidateScoredLayout.assemble(CandidateScoredLayout.Input(
            hiragana: "じょう",
            fixedSlot: .none,
            scored: scored,
            numberCandidates: [],
            dateTimeCandidates: [],
            historyOutputSet: ["上", "情報共有"]
        ))
        XCTAssertEqual(Array(layout.candidates.prefix(3)), ["情報共有", "上", "情"])
        XCTAssertEqual(layout.fixedEnd, 0)
        XCTAssertEqual(layout.historyEnd, 2)
    }

    func testHiraganaFixedSlotPrepended() {
        let layout = CandidateScoredLayout.assemble(CandidateScoredLayout.Input(
            hiragana: "の",
            fixedSlot: .hiragana,
            scored: [],
            numberCandidates: [],
            dateTimeCandidates: [],
            historyOutputSet: []
        ))
        XCTAssertEqual(layout.candidates, ["の"])
        XCTAssertEqual(layout.fixedEnd, 1)
        XCTAssertEqual(layout.historyEnd, 1)
    }
}
