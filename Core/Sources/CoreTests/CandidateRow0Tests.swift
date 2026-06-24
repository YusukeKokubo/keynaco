import XCTest
@testable import KeynacoCore

/// 統一スコアリング後の row 0（`CandidateScoredLayout.candidates.first`）を
/// source 種別ごとに固定する回帰テスト。
final class CandidateRow0Tests: XCTestCase {

    private func topCandidate(
        reading: String,
        exact: [String] = [],
        exactScores: [String: Double] = [:],
        userExact: [String] = [],
        azooKey: [String] = []
    ) -> String? {
        let entries = exact.compactMap { o in
            exactScores[o].map { HistoryEntry(output: o, score: .exact($0)) }
        }
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: reading,
            hiraganaBonus: nil,
            historyEntries: entries,
            userDictExact: userExact,
            userDictPrefix: [],
            azooKeyCandidates: azooKey,
            azooKeyApiOrder: [],
            numberCandidates: [],
            dateTimeCandidates: []
        ))
        return CandidateScoredLayout.assemble(CandidateScoredLayout.Input(scored: scored))
            .candidates.first
    }

    /// 履歴 exact が cutoff 以上なら row 0
    func testExactHistoryTakesRow0() {
        let top = topCandidate(
            reading: "あい",
            exact: ["感じ"],
            exactScores: ["感じ": 0.5]
        )
        XCTAssertEqual(top, "感じ")
    }

    /// userDict exact が AzooKey より上
    func testUserDictExactTakesRow0OverAzooKey() {
        let top = topCandidate(
            reading: "あい",
            userExact: ["藍"],
            azooKey: ["愛"]
        )
        XCTAssertEqual(top, "藍")
    }

    /// userDict exact > 低 score 履歴 exact（PLAN260624b 仕様変更）
    /// scoreBuilder のスコア順を採用。明示登録 > 偶然の低頻度履歴。
    func testUserDictExactBeatsLowScoreHistoryExact() {
        let top = topCandidate(
            reading: "あい",
            exact: ["相"],
            exactScores: ["相": 0.5],
            userExact: ["藍"]
        )
        XCTAssertEqual(top, "藍")
    }

    /// AzooKey 単独なら rank 0 が row 0
    func testAzooKeyRank0TakesRow0() {
        let top = topCandidate(
            reading: "あい",
            azooKey: ["愛", "藍"]
        )
        XCTAssertEqual(top, "愛")
    }

    /// AzooKey が reading の真部分文字列を rank 0 で返した場合も短い方が勝つ
    func testAzooKeyShorterPrefixTakesRow0() {
        let top = topCandidate(
            reading: "これでは",
            azooKey: ["これで", "これでは", "コレデ"]
        )
        XCTAssertEqual(top, "これで")
    }

}
