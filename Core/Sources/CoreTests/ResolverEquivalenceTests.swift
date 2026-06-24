import XCTest
@testable import KeynacoCore

/// PLAN260624b Phase 1: `InitialRowPolicyResolver` の各ケースが
/// `CandidateScoreBuilder` + `CandidateScoredLayout` の row 0 と一致するか可視化する。
///
/// `.explicit` トリガで resolver が `.firstMatching(X)` を返すとき、
/// scoreBuilder 経由でも layout.candidates.first == X になるなら resolver から
/// その分岐を削除できる候補。一致しないケースは scoreBuilder のスコア設計
/// 変更が要るか、resolver に残すかの判断対象。
final class ResolverEquivalenceTests: XCTestCase {

    private func topCandidate(
        reading: String,
        exact: [String] = [],
        exactScores: [String: Double] = [:],
        userExact: [String] = [],
        azooKey: [String] = []
    ) -> String? {
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: reading,
            hiraganaBonus: nil,
            exactMatchHighHistory: exact,
            highHistory: [],
            exactMatchScores: exactScores,
            prefixHistoryScores: [:],
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

    /// resolver: exact 履歴あれば最優先 → scoreBuilder でも同じ row 0
    func testExactHistoryAbsorbsResolver() {
        let top = topCandidate(
            reading: "あい",
            exact: ["感じ"],
            exactScores: ["感じ": 0.5]
        )
        XCTAssertEqual(top, "感じ")
    }

    /// resolver: userDict exact あれば次に → scoreBuilder でも row 0
    func testUserDictExactAbsorbsResolver() {
        let top = topCandidate(
            reading: "あい",
            userExact: ["藍"],
            azooKey: ["愛"]
        )
        XCTAssertEqual(top, "藍")
    }

    /// resolver: history > userDict
    /// scoreBuilder では historyDisplayScore=10.001 < userDictExactScore=50 で **失敗が期待**。
    /// これが Phase 2 着手の障害になるかどうかの可視化テスト。
    func testHistoryBeatsUserDictMayDiverge() {
        let top = topCandidate(
            reading: "あい",
            exact: ["相"],
            exactScores: ["相": 0.5],
            userExact: ["藍"]
        )
        // 現状の scoreBuilder では userDict(50) > history(10.001) なので "藍" が row 0
        // resolver は "相" を期待
        // → PLAN260624 未決項目 1 が POC 未確定の証拠
        XCTAssertEqual(top, "藍", "scoreBuilder の現状定数では userDict が history を上回る (PLAN260624 未決 1)")
    }

    /// resolver: AzooKey 単独先頭
    func testAzooKeyFirstAbsorbsResolver() {
        let top = topCandidate(
            reading: "あい",
            azooKey: ["愛", "藍"]
        )
        XCTAssertEqual(top, "愛")
    }

    /// resolver: AzooKey が reading の prefix でないケースは単純 row 0
    func testAzooKeyNotPrefixAbsorbsResolver() {
        let top = topCandidate(
            reading: "あい",
            azooKey: ["愛", "あい"]
        )
        XCTAssertEqual(top, "愛")
    }

    /// resolver の特殊分岐: reading が真部分文字列 azooKey より優先
    /// scoreBuilder では azooKey rank 0(=これで)=10 vs rank 1(=これでは)=5 で
    /// 短い方が勝つ → resolver の特殊ロジックは scoreBuilder では再現不可。
    func testReadingPreferOverAzooKeyPrefixCannotBeAbsorbed() {
        let top = topCandidate(
            reading: "これでは",
            azooKey: ["これで", "これでは", "コレデ"]
        )
        // 現状の scoreBuilder では "これで"(rank 0, score 10) が row 0
        // resolver は "これでは" を期待
        // → これが Phase 3 で resolver に「残す 1 分岐」の正体
        XCTAssertEqual(top, "これで", "scoreBuilder では reading 全体ブーストが無く、短い AzooKey rank 0 が勝つ")
    }
}
