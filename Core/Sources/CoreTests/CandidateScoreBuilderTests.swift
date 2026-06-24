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
        var byOutput: [String: HistoryEntry] = [:]
        var order: [String] = []
        for o in exact {
            guard let s = exactScores[o] else { continue }
            byOutput[o] = HistoryEntry(output: o, score: .exact(s))
            order.append(o)
        }
        for o in prefix where byOutput[o] == nil {
            guard let s = prefixScores[o] else { continue }
            byOutput[o] = HistoryEntry(output: o, score: .prefix(s))
            order.append(o)
        }
        for o in prefix {
            guard let s = prefixScores[o], let prev = byOutput[o], prev.prefixScore == nil else { continue }
            byOutput[o] = prev.addingPrefix(s)
        }
        let entries = order.compactMap { byOutput[$0] }
        return CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: reading,
            hiraganaBonus: hiraganaBonus,
            historyEntries: entries,
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

    /// **不変条件回帰テスト**: 履歴は dbScore がいくら低くても `azooKeyScore(rank: 0) + 0.001`
    /// 以上に底上げされる（`historyDisplayScore`）。これにより載った履歴は AzooKey 先頭より
    /// 必ず前に並ぶ。floor を外すと低スコア履歴が AzooKey の後ろに沈む。
    func testHistoryAlwaysAheadOfAzooKeyRankZero() {
        let scored = build(
            exact: ["低"],
            exactScores: ["低": 0.6],  // cutoff 直上、azooKeyScore(0)=10 より遥かに低い
            azooKey: ["A", "B", "C"]
        )
        XCTAssertEqual(scored.first?.text, "低", "低スコア履歴でも azooKey rank 0 より前")
        XCTAssertGreaterThan(
            scored[0].score, CandidateScoreBuilder.azooKeyScore(rank: 0),
            "履歴の display score は必ず azooKey rank 0 より大きい"
        )
    }

    /// **不変条件回帰テスト**: 同 output に exact / prefix 両方の score が乗っている `.both` で、
    /// upsert の dedup は「高スコア優先 → 同点なら sourceSortKey 小（= exact 側）」で解決する。
    /// production の `collectLocalCandidateSources` は exact 優先で抜くため `.both` は稀だが、
    /// builder 単体としての契約は維持する。
    func testHistoryEntryWithBothScoresPrefersExactOnTie() {
        let entry = HistoryEntry(output: "漢字", score: .both(exact: 50, prefix: 50))
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: "かんじ",
            hiraganaBonus: nil,
            historyEntries: [entry],
            userDictExact: [], userDictPrefix: [],
            azooKeyCandidates: [], azooKeyApiOrder: [],
            numberCandidates: [], dateTimeCandidates: []
        ))
        XCTAssertEqual(scored.filter { $0.text == "漢字" }.count, 1, "重複行は dedup されるはず")
        XCTAssertEqual(scored.first?.source, .historyExact, "同点なら sourceSortKey 小 = exact 側が勝つ")
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

    /// **境界回帰テスト**: bonus 置換は `bonusScore >= existing.score`（`>=`、同点で bonus 勝ち）。
    /// `>` に書き換わると同点ケースで history 側が残り、UI 上のセクション帰属が無音で変わる。
    func testHiraganaBuiltinBonusWinsOnExactTieWithHistory() {
        let scored = build(
            reading: "の",
            hiraganaBonus: .builtin,
            exact: ["の"],
            exactScores: ["の": CandidateScoreBuilder.hiraganaBuiltinBonus],
            azooKey: ["ノ"]
        )
        let target = scored.first(where: { $0.text == "の" })
        XCTAssertEqual(
            target?.source, .hiraganaBuiltin,
            "bonus 同点では bonus 側が勝つ（`>=` の境界）。`>` に変えるとこのテストが落ちる"
        )
        XCTAssertEqual(target?.score, CandidateScoreBuilder.hiraganaBuiltinBonus)
    }

    func testHiraganaUserBonusWinsOnExactTieWithHistory() {
        let scored = build(
            reading: "の",
            hiraganaBonus: .userSetting,
            exact: ["の"],
            exactScores: ["の": CandidateScoreBuilder.hiraganaUserBonus],
            azooKey: ["ノ"]
        )
        let target = scored.first(where: { $0.text == "の" })
        XCTAssertEqual(target?.source, .hiraganaPreferred)
        XCTAssertEqual(target?.score, CandidateScoreBuilder.hiraganaUserBonus)
    }
}

final class CandidateScoredLayoutTests: XCTestCase {

    func testGlobalScoreOrderPreservesRanking() {
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: "じょう",
            hiraganaBonus: nil,
            historyEntries: [
                HistoryEntry(output: "上", score: .exact(9)),
                HistoryEntry(output: "情報共有", score: .prefix(93)),
            ],
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
    }

    func testHiraganaBonusInterleavesByScoreNotTier() {
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: "の",
            hiraganaBonus: .builtin,
            historyEntries: [HistoryEntry(output: "ノックアウト", score: .prefix(25))],
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
    }

    func testNumberCandidatesMergeByScore() {
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: "1234",
            hiraganaBonus: nil,
            historyEntries: [],
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
