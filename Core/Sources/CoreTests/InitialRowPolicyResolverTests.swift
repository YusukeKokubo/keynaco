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
        azooKeyCandidates: [String] = []
    ) -> InitialRowPolicy {
        InitialRowPolicyResolver.resolve(InitialRowPolicyInput(
            reading: reading,
            fixedSlot: fixedSlot,
            hiraganaInHistory: hiraganaInHistory,
            addsDefaultFixedHiragana: addsDefaultFixedHiragana,
            exactMatchHighHistory: exactMatchHighHistory,
            userDictExact: userDictExact,
            azooKeyCandidates: azooKeyCandidates
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

    /// 組成読みが AzooKey 候補に含まれるとき、先頭の短い前方一致より読み完全一致を優先する。
    func testAzooKeyPrefersFullReadingOverShorterPrefix() {
        XCTAssertEqual(
            resolve(
                reading: "これでは",
                azooKeyCandidates: ["これで", "これでは", "コレデ"]
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
}
