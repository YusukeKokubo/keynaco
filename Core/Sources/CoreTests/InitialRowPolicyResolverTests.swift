import XCTest
@testable import KeynacoCore

final class InitialRowPolicyResolverTests: XCTestCase {

    private func resolve(
        reading: String = "あい",
        fixedSlot: CandidateFixedSlot = .none,
        hiraganaInHistory: Bool = false,
        addsDefaultFixedHiragana: Bool = false,
        zenzaiPromoted: String? = nil,
        exactMatchHighHistory: [String] = []
    ) -> InitialRowPolicy {
        InitialRowPolicyResolver.resolve(InitialRowPolicyInput(
            reading: reading,
            fixedSlot: fixedSlot,
            hiraganaInHistory: hiraganaInHistory,
            addsDefaultFixedHiragana: addsDefaultFixedHiragana,
            zenzaiPromoted: zenzaiPromoted,
            exactMatchHighHistory: exactMatchHighHistory
        ))
    }

    func testHiraganaFixedSlot() {
        XCTAssertEqual(resolve(reading: "の", fixedSlot: .hiragana), .firstMatching("の"))
    }

    func testDefaultFixedWithZenzai() {
        XCTAssertEqual(
            resolve(addsDefaultFixedHiragana: true, zenzaiPromoted: "Zen"),
            .atZero
        )
    }

    func testDefaultFixedWithoutZenzai() {
        XCTAssertEqual(
            resolve(reading: "あい", addsDefaultFixedHiragana: true),
            .firstMatching("あい")
        )
    }

    func testHiraganaInHistoryWithZenzai() {
        XCTAssertEqual(
            resolve(reading: "したい", hiraganaInHistory: true, zenzaiPromoted: "Zen"),
            .firstMatching("したい")
        )
    }

    func testZenzaiWithoutDefaultFixed() {
        XCTAssertEqual(resolve(zenzaiPromoted: "Zen"), .atZero)
    }

    func testAfterFixedDefault() {
        XCTAssertEqual(resolve(), .afterFixed)
    }

    func testExactMatchHistoryOverridesZenzai() {
        XCTAssertEqual(
            resolve(zenzaiPromoted: "Zen", exactMatchHighHistory: ["感じ"]),
            .firstMatching("感じ")
        )
    }
}
