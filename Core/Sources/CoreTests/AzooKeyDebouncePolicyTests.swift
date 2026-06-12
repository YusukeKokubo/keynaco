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
