import XCTest
@testable import KeynacoCore

final class InitialRowPolicyResolverTests: XCTestCase {

    private func resolve(
        reading: String = "あい",
        exactMatchHighHistory: [String] = [],
        userDictExact: [String] = [],
        azooKeyCandidates: [String] = [],
        candidateList: [String] = []
    ) -> InitialRowPolicy {
        InitialRowPolicyResolver.resolve(InitialRowPolicyInput(
            reading: reading,
            exactMatchHighHistory: exactMatchHighHistory,
            userDictExact: userDictExact,
            azooKeyCandidates: azooKeyCandidates,
            candidateList: candidateList
        ))
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

    func testUserDictExactSelectedWhenNoHistory() {
        XCTAssertEqual(
            resolve(userDictExact: ["藍"], azooKeyCandidates: ["愛"]),
            .firstMatching("藍")
        )
    }

    func testHistoryBeatsUserDictExact() {
        XCTAssertEqual(
            resolve(exactMatchHighHistory: ["相"], userDictExact: ["藍"]),
            .firstMatching("相")
        )
    }

    func testAzooKeyFirstSelectedWhenNoHistoryNoUserDict() {
        XCTAssertEqual(
            resolve(azooKeyCandidates: ["愛", "藍"]),
            .firstMatching("愛")
        )
    }

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

    func testAzooKeyFirstUnchangedWhenNotPrefixOfReading() {
        XCTAssertEqual(
            resolve(reading: "あい", azooKeyCandidates: ["愛", "あい"]),
            .firstMatching("愛")
        )
    }
}
