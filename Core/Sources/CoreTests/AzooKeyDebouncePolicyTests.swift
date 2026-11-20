import XCTest
@testable import KeynacoCore

final class AzooKeyDebouncePolicyTests: XCTestCase {

    func testFastTypingUsesLongerDebounce() {
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 50,
            hasPendingRomaji: false,
            readingLength: 4
        ))
        XCTAssertEqual(ns, 80_000_000)
    }

    func testNormalTypingUsesBalancedDebounce() {
        // 通常打鍵速度（実測 inter_key_p50 ≈ 128ms）。子音キーで fetch を捨てなくなったので 60ms まで詰める（PLAN260929a）。
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 120,
            hasPendingRomaji: false,
            readingLength: 4
        ))
        XCTAssertEqual(ns, 60_000_000)
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
        XCTAssertEqual(ns, 80_000_000)
    }

    func testFirstKeyUsesDefault() {
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: nil,
            hasPendingRomaji: false,
            readingLength: 4
        ))
        XCTAssertEqual(ns, AzooKeyDebouncePolicy.defaultNanoseconds)
    }

    // 読み長 ≤2 で打鍵中（pause 未検知）は wasted fetch 削減のため 90ms を下限にする。
    func testShortReadingDuringTypingBumpsToMax() {
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 120,
            hasPendingRomaji: false,
            readingLength: 2
        ))
        XCTAssertEqual(ns, 90_000_000)
    }

    func testShortReadingFastTypingStillBumps() {
        // fast bucket（80ms）でも 90ms まで伸ばす。
        let ns = AzooKeyDebouncePolicy.nanoseconds(for: AzooKeyDebounceInput(
            interKeyIntervalMs: 50,
            hasPendingRomaji: false,
            readingLength: 1
        ))
        XCTAssertEqual(ns, 90_000_000)
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
        XCTAssertEqual(ns, 60_000_000)
    }

    // MARK: - 実験用 override

    /// override が立っとる間は、通常なら 120ms 床が効く条件（短読み・pause なし）でも上書き値が勝つ。
    /// これが効かんと「debounce を詰めたらロック待ちが復活するか」の実験そのものが成立せん。
    func testOverrideWinsOverPolicyIncludingShortReadingFloor() {
        let ns = AzooKeyDebouncePolicy.resolveNanoseconds(
            overrideMs: 70,
            input: AzooKeyDebounceInput(
                interKeyIntervalMs: 60,
                hasPendingRomaji: false,
                readingLength: 2
            )
        )
        XCTAssertEqual(ns, 70_000_000)
    }

    /// override は clamp を通さない（40ms 未満も実験できることが要件）。
    func testOverrideBypassesLowerClamp() {
        let ns = AzooKeyDebouncePolicy.resolveNanoseconds(
            overrideMs: 20,
            input: AzooKeyDebounceInput(interKeyIntervalMs: 60, hasPendingRomaji: false, readingLength: 4)
        )
        XCTAssertEqual(ns, 20_000_000)
    }

    /// 未設定・0 以下は通常ポリシーに落ちる（実験を戻し忘れても本番挙動が変わらんこと）。
    func testNilOrNonPositiveOverrideFallsBackToPolicy() {
        let input = AzooKeyDebounceInput(interKeyIntervalMs: 120, hasPendingRomaji: false, readingLength: 3)
        let policy = AzooKeyDebouncePolicy.nanoseconds(for: input)
        XCTAssertEqual(AzooKeyDebouncePolicy.resolveNanoseconds(overrideMs: nil, input: input), policy)
        XCTAssertEqual(AzooKeyDebouncePolicy.resolveNanoseconds(overrideMs: 0, input: input), policy)
        XCTAssertEqual(AzooKeyDebouncePolicy.resolveNanoseconds(overrideMs: -5, input: input), policy)
    }
}
