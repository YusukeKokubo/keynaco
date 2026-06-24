import XCTest
@testable import KeynacoCore

/// PLAN260624b Phase 1〜3: 旧 `InitialRowPolicyResolver` の挙動を
/// `CandidateScoreBuilder` + `CandidateScoredLayout` に統合した後の row 0 を保証する。
///
/// resolver 完全削除（`.explicit` でも row 0 = layout.candidates.first）の仕様を
/// 各 source 種別ごとに固定する回帰テスト。
final class ResolverEquivalenceTests: XCTestCase {

    private func topCandidate(
        reading: String,
        exact: [String] = [],
        exactScores: [String: Double] = [:],
        userExact: [String] = [],
        azooKey: [String] = []
    ) -> String? {
        let entries = exact.compactMap { o in
            exactScores[o].map { HistoryEntry(output: o, exactScore: $0) }
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
    /// 旧 resolver では「履歴 > userDict」だったが、シンプル化方針として
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
    /// （PLAN260624b 仕様変更: 実機 sandbox で AzooKey/Zenzai はこのケースを
    /// 出さないため、resolver の特殊ロジックは dead code と判定）
    func testAzooKeyShorterPrefixTakesRow0() {
        let top = topCandidate(
            reading: "これでは",
            azooKey: ["これで", "これでは", "コレデ"]
        )
        XCTAssertEqual(top, "これで")
    }

}
