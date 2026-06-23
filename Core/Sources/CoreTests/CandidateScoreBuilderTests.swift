import XCTest
@testable import KeynacoCore

final class CandidateScoreBuilderTests: XCTestCase {

    private func build(
        reading: String = "じょう",
        hiraganaBonus: CandidateScoreBuilder.HiraganaBonusKind? = nil,
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
            reading: reading,
            hiraganaBonus: hiraganaBonus,
            exactMatchHighHistory: exact,
            highHistory: prefix,
            exactMatchScores: exactScores,
            prefixHistoryScores: prefixScores,
            userDictExact: userExact,
            userDictPrefix: userPrefix,
            azooKeyCandidates: azooKey,
            azooKeyApiOrder: azooOrder,
            numberCandidates: [],
            dateTimeCandidates: []
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
        XCTAssertEqual(scored.map(\.text), ["情報共有", "上", "情", "条"])
        XCTAssertEqual(scored[0].source, .historyPrefix)
        XCTAssertEqual(scored[1].source, .historyExact)
    }

    func testUserDictExactScoreBetweenHistoryAndAzooKey() {
        let scored = build(
            exact: ["低"],
            exactScores: ["低": 9],
            userExact: ["UD語"],
            azooKey: ["辞書A"]
        )
        XCTAssertEqual(scored.map(\.text), ["UD語", "低", "辞書A"])
        XCTAssertEqual(scored[0].score, CandidateScoreBuilder.userDictExactScore)
        XCTAssertEqual(scored[1].score, CandidateScoreBuilder.azooKeyScore(rank: 0) + 0.001, accuracy: 0.0001)
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

    func testHiraganaBuiltinBonusBeatsWrongHistory() {
        let scored = build(
            reading: "の",
            hiraganaBonus: .builtin,
            prefix: ["ノックアウト"],
            prefixScores: ["ノックアウト": 25],
            azooKey: ["ノ", "之"]
        )
        XCTAssertEqual(scored.first?.text, "の")
        XCTAssertEqual(scored.first?.source, .hiraganaBuiltin)
        XCTAssertEqual(scored.first?.score, CandidateScoreBuilder.hiraganaBuiltinBonus)
    }

    func testHiraganaBonusUsesMaxWithExactHistory() {
        let scored = build(
            reading: "の",
            hiraganaBonus: .builtin,
            exact: ["の"],
            exactScores: ["の": 120],
            azooKey: ["ノ"]
        )
        XCTAssertEqual(scored.filter { $0.text == "の" }.count, 1)
        XCTAssertEqual(scored.first(where: { $0.text == "の" })?.source, .historyExact)
        XCTAssertEqual(scored.first(where: { $0.text == "の" })?.score, 120)
    }

    func testHiraganaBonusReplacesLowExactHistory() {
        let scored = build(
            reading: "の",
            hiraganaBonus: .builtin,
            exact: ["の"],
            exactScores: ["の": 5],
            azooKey: ["ノ"]
        )
        XCTAssertEqual(scored.first(where: { $0.text == "の" })?.source, .hiraganaBuiltin)
        XCTAssertEqual(scored.first(where: { $0.text == "の" })?.score, 80)
    }
}

final class CandidateScoredLayoutTests: XCTestCase {

    func testGlobalScoreOrderPreservesRanking() {
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: "じょう",
            hiraganaBonus: nil,
            exactMatchHighHistory: ["上"],
            highHistory: ["情報共有"],
            exactMatchScores: ["上": 9],
            prefixHistoryScores: ["情報共有": 93],
            userDictExact: [],
            userDictPrefix: [],
            azooKeyCandidates: ["情"],
            azooKeyApiOrder: [],
            numberCandidates: [],
            dateTimeCandidates: []
        ))
        let layout = CandidateScoredLayout.assemble(CandidateScoredLayout.Input(scored: scored))
        XCTAssertEqual(Array(layout.candidates.prefix(3)), ["情報共有", "上", "情"])
        XCTAssertEqual(Array(layout.sources.prefix(3)), [.historyPrefix, .historyExact, .azooKey(rank: 0)])
        XCTAssertEqual(layout.fixedEnd, 0)
        XCTAssertEqual(layout.historyEnd, 2)
    }

    func testHiraganaBonusInterleavesByScoreNotTier() {
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: "の",
            hiraganaBonus: .builtin,
            exactMatchHighHistory: [],
            highHistory: ["ノックアウト"],
            exactMatchScores: [:],
            prefixHistoryScores: ["ノックアウト": 25],
            userDictExact: [],
            userDictPrefix: [],
            azooKeyCandidates: ["ノ", "之"],
            azooKeyApiOrder: [],
            numberCandidates: [],
            dateTimeCandidates: []
        ))
        let layout = CandidateScoredLayout.assemble(CandidateScoredLayout.Input(scored: scored))
        XCTAssertEqual(Array(layout.candidates.prefix(3)), ["の", "ノックアウト", "ノ"])
        XCTAssertEqual(layout.sources.count, layout.candidates.count)
        XCTAssertEqual(layout.fixedEnd, 1)
        XCTAssertEqual(layout.historyEnd, 2)
    }

    func testNumberCandidatesMergeByScore() {
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: "1234",
            hiraganaBonus: nil,
            exactMatchHighHistory: [],
            highHistory: [],
            exactMatchScores: [:],
            prefixHistoryScores: [:],
            userDictExact: [],
            userDictPrefix: [],
            azooKeyCandidates: [],
            azooKeyApiOrder: [],
            numberCandidates: ["1234", "１２３４"],
            dateTimeCandidates: []
        ))
        let layout = CandidateScoredLayout.assemble(CandidateScoredLayout.Input(scored: scored))
        XCTAssertEqual(layout.candidates, ["1234", "１２３４"])
        XCTAssertEqual(layout.sources, [.number, .number])
    }
}
