import XCTest
@testable import KeynacoCore

final class AzooKeyDebouncePolicyTests: XCTestCase {

    func testFastTypingUsesLongerDebounce() {
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 50,
            hasPendingRomaji: false
        ))
        XCTAssertEqual(ns, 110_000_000)
    }

    func testNormalTypingUsesBalancedDebounce() {
        // 通常打鍵速度（実測 inter_key_p50 ≈ 117ms）。fetch コスト 80ms 程度を上回る 90ms に設定。
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 120,
            hasPendingRomaji: false
        ))
        XCTAssertEqual(ns, 90_000_000)
    }

    func testPauseUsesShorterDebounce() {
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 200,
            hasPendingRomaji: false
        ))
        XCTAssertEqual(ns, 45_000_000)
    }

    func testPendingRomajiUsesLongerDebounce() {
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 200,
            hasPendingRomaji: true
        ))
        XCTAssertEqual(ns, 105_000_000)
    }

    func testFirstKeyUsesDefault() {
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: nil,
            hasPendingRomaji: false
        ))
        XCTAssertEqual(ns, AzooKeyDebouncePolicy.defaultNanoseconds)
    }
}
