import XCTest
@testable import KeynacoCore

final class AzooKeyCachePeekTests: XCTestCase {

    func testExactCacheHit() {
        let converter = AzooKeyConverter()
        _ = converter.requestCandidates(hiragana: "かんじ", leftSideContext: nil, richCandidates: true)
        let peek = converter.peekCachedCandidates(hiragana: "かんじ", leftSideContext: nil, richCandidates: true)
        XCTAssertEqual(peek?.match, .exact)
        XCTAssertFalse(peek?.candidates.isEmpty ?? true)
        XCTAssertEqual(peek?.needsAsyncFetch, false)
    }

    func testPrefixCacheHitFromLongerCachedReading() {
        let converter = AzooKeyConverter()
        _ = converter.requestCandidates(hiragana: "かん", leftSideContext: nil, richCandidates: true)
        let peek = converter.peekCachedCandidates(hiragana: "かんじ", leftSideContext: nil, richCandidates: true)
        XCTAssertEqual(peek?.match, .prefix(sourceReading: "かん"))
        XCTAssertFalse(peek?.candidates.isEmpty ?? true)
        XCTAssertEqual(peek?.needsAsyncFetch, true)
    }

    func testMissWhenNoCache() {
        let converter = AzooKeyConverter()
        let peek = converter.peekCachedCandidates(hiragana: "てすと", leftSideContext: nil, richCandidates: true)
        XCTAssertNil(peek)
    }
}
