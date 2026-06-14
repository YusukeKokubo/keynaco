import XCTest
@testable import KeynacoCore

final class InitialRowPolicyResolverTests: XCTestCase {

    private func resolve(
        reading: String = "あい",
        fixedSlot: CandidateFixedSlot = .none,
        hiraganaInHistory: Bool = false,
        addsDefaultFixedHiragana: Bool = false,
        exactMatchHighHistory: [String] = [],
        userDictExact: [String] = [],
        prefixFocusCandidate: String? = nil,
        azooKeyCandidates: [String] = [],
        candidateList: [String] = []
    ) -> InitialRowPolicy {
        InitialRowPolicyResolver.resolve(InitialRowPolicyInput(
            reading: reading,
            fixedSlot: fixedSlot,
            hiraganaInHistory: hiraganaInHistory,
            addsDefaultFixedHiragana: addsDefaultFixedHiragana,
            exactMatchHighHistory: exactMatchHighHistory,
            userDictExact: userDictExact,
            prefixFocusCandidate: prefixFocusCandidate,
            azooKeyCandidates: azooKeyCandidates,
            candidateList: candidateList
        ))
    }

    func testHiraganaFixedSlot() {
        XCTAssertEqual(resolve(reading: "の", fixedSlot: .hiragana), .firstMatching("の"))
    }

    func testDefaultFixed() {
        XCTAssertEqual(
            resolve(reading: "あい", addsDefaultFixedHiragana: true),
            .firstMatching("あい")
        )
    }

    func testAfterFixedDefault() {
        XCTAssertEqual(resolve(), .afterFixed)
    }

    func testExactMatchHistorySelectedFirst() {
        XCTAssertEqual(
            resolve(exactMatchHighHistory: ["感じ"]),
            .firstMatching("感じ")
        )
    }

    /// 履歴ヒット無しでも、ユーザー辞書 exact があれば初期選択する。
    func testUserDictExactSelectedWhenNoHistory() {
        XCTAssertEqual(
            resolve(userDictExact: ["藍"], azooKeyCandidates: ["愛"]),
            .firstMatching("藍")
        )
    }

    /// 履歴とユーザー辞書 exact が両方あれば履歴が勝つ。
    func testHistoryBeatsUserDictExact() {
        XCTAssertEqual(
            resolve(exactMatchHighHistory: ["相"], userDictExact: ["藍"]),
            .firstMatching("相")
        )
    }

    /// 履歴・ユーザー辞書 exact 無しで AzooKey 辞書だけあるとき、AzooKey 先頭を選ぶ。
    func testAzooKeyFirstSelectedWhenNoHistoryNoUserDict() {
        XCTAssertEqual(
            resolve(azooKeyCandidates: ["愛", "藍"]),
            .firstMatching("愛")
        )
    }

    /// AzooKey が選ばれるなら addsDefaultFixedHiragana のひらがな自動選択はバイパスする。
    func testAzooKeyBeatsDefaultFixedHiragana() {
        XCTAssertEqual(
            resolve(addsDefaultFixedHiragana: true, azooKeyCandidates: ["愛"]),
            .firstMatching("愛")
        )
    }

    /// 統合候補の先頭が組成読みなら、AzooKey 先頭より優先する。
    func testPrefersReadingWhenFirstInCandidateList() {
        XCTAssertEqual(
            resolve(
                reading: "うおうお",
                azooKeyCandidates: ["うお", "魚屋"],
                candidateList: ["うおうお", "うお", "魚屋", "ウオ"]
            ),
            .firstMatching("うおうお")
        )
    }

    /// 先頭が組成読みでないとき、AzooKey 短い前方一致より読み完全一致を優先する。
    func testPrefersFullReadingOverAzooKeyShorterPrefix() {
        XCTAssertEqual(
            resolve(
                reading: "これでは",
                azooKeyCandidates: ["これで", "これでは", "コレデ"],
                candidateList: ["これで", "これでは", "コレデ"]
            ),
            .firstMatching("これでは")
        )
    }

    /// 先頭候補が短い前方一致でなければ、従来どおり AzooKey 先頭を選ぶ。
    func testAzooKeyFirstUnchangedWhenNotPrefixOfReading() {
        XCTAssertEqual(
            resolve(reading: "あい", azooKeyCandidates: ["愛", "あい"]),
            .firstMatching("愛")
        )
    }

    /// 前方一致フォーカスは AzooKey 先頭より優先する。
    func testPrefixFocusBeatsAzooKeyFirst() {
        XCTAssertEqual(
            resolve(
                reading: "だけんす",
                prefixFocusCandidate: "打鍵数削減",
                azooKeyCandidates: ["ダケンス", "打鍵末"],
                candidateList: ["打鍵数削減", "ダケンス", "だけんす", "打鍵末"]
            ),
            .firstMatching("打鍵数削減")
        )
    }

    /// 完全一致履歴は前方一致フォーカスより優先する。
    func testExactMatchHistoryBeatsPrefixFocus() {
        XCTAssertEqual(
            resolve(
                exactMatchHighHistory: ["感じ"],
                prefixFocusCandidate: "漢字",
                azooKeyCandidates: ["愛"]
            ),
            .firstMatching("感じ")
        )
    }

    func testPrefixFocusCandidate_nounLcidAccepted() {
        let focus = InitialRowPolicyResolver.prefixFocusCandidate(
            reading: "だけんす",
            prefixHistory: ["打鍵数削減", "動詞"],
            userDictPrefix: [],
            rankForOutput: { text in
                text == "打鍵数削減" ? .noun : .verb
            }
        )
        XCTAssertEqual(focus, "打鍵数削減")
    }

    func testPrefixFocusCandidate_acceptsVerbAtThreeMorae() {
        let focus = InitialRowPolicyResolver.prefixFocusCandidate(
            reading: "だけんす",
            prefixHistory: ["出る"],
            userDictPrefix: [],
            rankForOutput: { _ in .verb }
        )
        XCTAssertEqual(focus, "出る")
    }

    func testPrefixFocusCandidate_skipsVerbBelowThreeMorae() {
        let focus = InitialRowPolicyResolver.prefixFocusCandidate(
            reading: "かん",
            prefixHistory: ["出る"],
            userDictPrefix: [],
            rankForOutput: { _ in .verb }
        )
        XCTAssertNil(focus)
    }

    func testPrefixFocusCandidate_acceptsAdjectiveAtFiveMorae() {
        let focus = InitialRowPolicyResolver.prefixFocusCandidate(
            reading: "おもしろい",
            prefixHistory: ["面白い"],
            userDictPrefix: [],
            rankForOutput: { _ in .adjective }
        )
        XCTAssertEqual(focus, "面白い")
    }

    func testPrefixFocusCandidate_skipsAdjectiveBelowFiveMorae() {
        let focus = InitialRowPolicyResolver.prefixFocusCandidate(
            reading: "おもし",
            prefixHistory: ["面白い"],
            userDictPrefix: [],
            rankForOutput: { _ in .adjective }
        )
        XCTAssertNil(focus)
    }

    func testPrefixFocusCandidate_skipsParticle() {
        let focus = InitialRowPolicyResolver.prefixFocusCandidate(
            reading: "だけんす",
            prefixHistory: ["だけ"],
            userDictPrefix: [],
            rankForOutput: { _ in .particle }
        )
        XCTAssertNil(focus)
    }

    func testPrefixFocusCandidate_requiresTwoMorae() {
        let focus = InitialRowPolicyResolver.prefixFocusCandidate(
            reading: "だ",
            prefixHistory: ["打鍵数削減"],
            userDictPrefix: [],
            rankForOutput: { _ in .noun }
        )
        XCTAssertNil(focus)
    }

    func testPrefixFocusCandidate_userDictPrefixAfterHistory() {
        let focus = InitialRowPolicyResolver.prefixFocusCandidate(
            reading: "だけんす",
            prefixHistory: ["だけ"],
            userDictPrefix: ["打鍵数削減"],
            rankForOutput: { text in
                text == "打鍵数削減" ? .noun : .particle
            }
        )
        XCTAssertEqual(focus, "打鍵数削減")
    }

    func testWhileTypingInitialRow_skipsIneligiblePrefixHistory() {
        let row = InitialRowPolicyResolver.whileTypingInitialRow(
            candidates: ["食べる", "タベ"],
            fixedEnd: 0,
            historyEnd: 1,
            computedRow: 0,
            reading: "たべ",
            exactMatchHistory: [],
            rankForOutput: { _ in .verb }
        )
        XCTAssertEqual(row, 1)
    }

    func testWhileTypingInitialRow_keepsExactMatchHistoryWithoutMoraGate() {
        let row = InitialRowPolicyResolver.whileTypingInitialRow(
            candidates: ["食べる"],
            fixedEnd: 0,
            historyEnd: 1,
            computedRow: 0,
            reading: "たべ",
            exactMatchHistory: ["食べる"],
            rankForOutput: { _ in .verb }
        )
        XCTAssertEqual(row, 0)
    }

    func testWhileTypingInitialRow_nilWhenOnlyIneligibleHistory() {
        let row = InitialRowPolicyResolver.whileTypingInitialRow(
            candidates: ["食べる"],
            fixedEnd: 0,
            historyEnd: 1,
            computedRow: 0,
            reading: "たべ",
            exactMatchHistory: [],
            rankForOutput: { _ in .verb }
        )
        XCTAssertNil(row)
    }

    func testWhileTypingInitialRow_prefersDictionaryAfterIneligibleHistory() {
        let row = InitialRowPolicyResolver.whileTypingInitialRow(
            candidates: ["打鍵数削減", "ダケンス", "だけんす"],
            fixedEnd: 0,
            historyEnd: 1,
            computedRow: 0,
            reading: "だけんす",
            exactMatchHistory: [],
            rankForOutput: { text in text == "打鍵数削減" ? .unknown : .noun }
        )
        XCTAssertEqual(row, 1)
    }
}
