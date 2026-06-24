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

    /// PLAN260624c: hiraganaPreferred (userSetting) で reading 行が必ず score 上 row 0
    func testUserSettingHiraganaBonusKeepsReadingAtRow0() {
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: "ない",
            hiraganaBonus: .userSetting,
            exactMatchHighHistory: ["内"],
            highHistory: [],
            exactMatchScores: ["内": 8.0],
            prefixHistoryScores: [:],
            userDictExact: [],
            userDictPrefix: [],
            azooKeyCandidates: ["無い", "ナイ"],
            azooKeyApiOrder: [],
            numberCandidates: [],
            dateTimeCandidates: []
        ))
        let top = CandidateScoredLayout
            .assemble(CandidateScoredLayout.Input(scored: scored))
            .candidates.first
        XCTAssertEqual(top, "ない", "userSetting bonus(100) が history(<= 10.001) を上回り row 0")
    }

    /// PLAN260624c: builtin reading に対する高 SUM の prefix history は builtin bonus(80) を
    /// 超えるため、scoreBuilder の row 0 は漢字側に来る。これは仕様: Space を意図的に押した
    /// 時は変換意図として row 0 (= 漢字) がフォーカスされる。助詞入力の実動線は whileTyping
    /// の builtin dismiss 経由で Space を経由しないため影響なし。
    func testBuiltinReadingLosesRow0WhenPrefixHistoryDominates() {
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: "は",
            hiraganaBonus: .builtin,
            exactMatchHighHistory: [],
            highHistory: ["話"],
            exactMatchScores: [:],
            prefixHistoryScores: ["話": 138.7],
            userDictExact: [],
            userDictPrefix: [],
            azooKeyCandidates: ["は", "歯"],
            azooKeyApiOrder: [],
            numberCandidates: [],
            dateTimeCandidates: []
        ))
        let top = CandidateScoredLayout
            .assemble(CandidateScoredLayout.Input(scored: scored))
            .candidates.first
        XCTAssertEqual(top, "話", "prefix history(138.7) が builtin bonus(80) を上回り score 上は row 0 = 話")
    }

    /// PLAN260624c: hiraganaPreferred (builtin) で reading 行が score 上 row 0
    func testBuiltinHiraganaBonusKeepsReadingAtRow0() {
        let scored = CandidateScoreBuilder.build(CandidateScoreBuilder.BuildInput(
            reading: "て",
            hiraganaBonus: .builtin,
            exactMatchHighHistory: ["手"],
            highHistory: [],
            exactMatchScores: ["手": 3.5],
            prefixHistoryScores: [:],
            userDictExact: [],
            userDictPrefix: [],
            azooKeyCandidates: ["手", "出"],
            azooKeyApiOrder: [],
            numberCandidates: [],
            dateTimeCandidates: []
        ))
        let top = CandidateScoredLayout
            .assemble(CandidateScoredLayout.Input(scored: scored))
            .candidates.first
        XCTAssertEqual(top, "て", "builtin bonus(80) が history(<= 10.001) を上回り row 0")
    }
}
