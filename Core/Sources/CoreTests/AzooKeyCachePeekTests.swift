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

    /// **不変条件回帰テスト**: 読み 2 文字以下では cache key に leftSideContext を含めない
    /// （Zenzai の文脈効果がほぼなく、含めるとミス率が増えるため）。3 文字からは含める。
    /// boundary 値を `< 2` や `<= 3` に書き換えるとこのテストが落ちる。
    func testCacheKeyIgnoresContextAtTwoCharsAndBelow() {
        let converter = AzooKeyConverter()
        // 2 文字: 文脈違いでも同じキャッシュエントリにヒットするはず
        _ = converter.requestCandidates(hiragana: "かん", leftSideContext: "コンテキストX", richCandidates: true)
        let twoCharPeek = converter.peekCachedCandidates(
            hiragana: "かん", leftSideContext: "コンテキストY", richCandidates: true
        )
        XCTAssertEqual(twoCharPeek?.match, .exact,
                       "2 文字読みは context を key に含めないため context 違いで exact hit")
    }

    func testCacheKeyIncludesContextAtThreeCharsAndAbove() {
        let converter = AzooKeyConverter()
        // 3 文字: 文脈違いだと別キャッシュ扱い（exact hit せず）
        _ = converter.requestCandidates(hiragana: "かんじ", leftSideContext: "コンテキストX", richCandidates: true)
        let threeCharPeek = converter.peekCachedCandidates(
            hiragana: "かんじ", leftSideContext: "コンテキストY", richCandidates: true
        )
        // 3 文字は context が key に入るので、context Y では exact 一致しない。
        // ただし prefix match（短い読みの cache）にもヒットしないので nil もしくは prefix 以外。
        XCTAssertNotEqual(threeCharPeek?.match, .exact,
                          "3 文字読みは context を key に含めるため context 違いで exact hit しない")
    }

    /// **不変条件回帰テスト**: cache に複数の prefix match があるとき、最長 prefix を選ぶ。
    /// `segment.count <= current.count` の `<=` を `<` に変えると最初に見つけた prefix が
    /// 勝ち続けて最長が選ばれなくなる。
    func testPrefixCacheSelectsLongestMatch() {
        let converter = AzooKeyConverter()
        _ = converter.requestCandidates(hiragana: "か", leftSideContext: nil, richCandidates: true)
        _ = converter.requestCandidates(hiragana: "かん", leftSideContext: nil, richCandidates: true)
        let peek = converter.peekCachedCandidates(hiragana: "かんじ", leftSideContext: nil, richCandidates: true)
        XCTAssertEqual(
            peek?.match, .prefix(sourceReading: "かん"),
            "複数 prefix の中から最長（「かん」、2 文字）が選ばれるはず（「か」1 文字ではない）"
        )
    }
}
