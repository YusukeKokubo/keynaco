import XCTest
@testable import KeynacoCore

/// Phase 3: rich 先読み後に `.explicit`（Space）同期呼び出しがキャッシュヒットすること。
final class AzooKeyRichPrefetchCacheTests: XCTestCase {

    func testRichPrefetchEnablesExplicitCacheHit() {
        let mock = MockAzooKeyRichPrefetch()
        let reading = "かんじ"

        _ = mock.requestCandidates(hiragana: reading, leftSideContext: nil, richCandidates: true)
        XCTAssertEqual(mock.requestCount, 1, "先読みで 1 回")

        _ = mock.requestCandidates(hiragana: reading, leftSideContext: nil, richCandidates: true)
        XCTAssertEqual(mock.requestCount, 1, "Space 相当の rich=true 再要求はキャッシュヒット")

        _ = mock.requestCandidates(hiragana: reading, leftSideContext: nil, richCandidates: false)
        XCTAssertEqual(mock.requestCount, 2, "rich=false は別キー")
    }
}

private final class MockAzooKeyRichPrefetch: AzooKeyConverting, @unchecked Sendable {
    var isZenzaiEnabled: Bool { false }
    let latencyStats = TypingLatencyStats()
    private(set) var requestCount = 0
    private var cache: [String: [AzooKeyCandidate]] = [:]

    private func cacheKey(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> String {
        let ctx = leftSideContext ?? ""
        return richCandidates ? "\(hiragana)|\(ctx)|rich" : "\(hiragana)|\(ctx)"
    }

    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [AzooKeyCandidate] {
        let key = cacheKey(hiragana: hiragana, leftSideContext: leftSideContext, richCandidates: richCandidates)
        if cache[key] != nil { return cache[key]! }
        requestCount += 1
        let result = [AzooKeyCandidate.text("候補")]
        cache[key] = result
        return result
    }

    func peekCachedCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> AzooKeyCachePeek? {
        nil
    }

    func commit(reading: String, text: String) { _ = (reading, text) }
}
