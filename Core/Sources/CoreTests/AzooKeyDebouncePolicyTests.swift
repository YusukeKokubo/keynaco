import XCTest
@testable import KeynacoCore

final class AzooKeyDebouncePolicyTests: XCTestCase {

    func testFastTypingUsesLongerDebounce() {
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 50,
            hasPendingRomaji: false,
            readingLength: 4
        ))
        XCTAssertEqual(ns, 110_000_000)
    }

    func testNormalTypingUsesBalancedDebounce() {
        // 通常打鍵速度（実測 inter_key_p50 ≈ 117ms）。fetch コスト 80ms 程度を上回る 90ms に設定。
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 120,
            hasPendingRomaji: false,
            readingLength: 4
        ))
        XCTAssertEqual(ns, 90_000_000)
    }

    func testPauseUsesShorterDebounce() {
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 200,
            hasPendingRomaji: false,
            readingLength: 4
        ))
        XCTAssertEqual(ns, 45_000_000)
    }

    func testPendingRomajiUsesLongerDebounce() {
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 200,
            hasPendingRomaji: true,
            readingLength: 4
        ))
        XCTAssertEqual(ns, 105_000_000)
    }

    func testFirstKeyUsesDefault() {
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: nil,
            hasPendingRomaji: false,
            readingLength: 4
        ))
        XCTAssertEqual(ns, AzooKeyDebouncePolicy.defaultNanoseconds)
    }

    // 読み長 ≤2 で打鍵中（pause 未検知）は wasted fetch 削減のため max=120ms に伸ばす。
    func testShortReadingDuringTypingBumpsToMax() {
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 120,
            hasPendingRomaji: false,
            readingLength: 2
        ))
        XCTAssertEqual(ns, 120_000_000)
    }

    func testShortReadingFastTypingStillBumps() {
        // 既に 110ms（fast bucket）でも 120ms まで伸ばす。
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 50,
            hasPendingRomaji: false,
            readingLength: 1
        ))
        XCTAssertEqual(ns, 120_000_000)
    }

    func testShortReadingWithPauseKeepsShortDebounce() {
        // ≥160ms の pause が来とったらユーザーが手を止めとる → 即発火（45ms）を尊重。
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 200,
            hasPendingRomaji: false,
            readingLength: 2
        ))
        XCTAssertEqual(ns, 45_000_000)
    }

    func testThreeCharReadingUnaffected() {
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 120,
            hasPendingRomaji: false,
            readingLength: 3
        ))
        XCTAssertEqual(ns, 90_000_000)
    }
}
