import XCTest
@testable import KeynacoCore

final class FetchRequestOutcomeTests: XCTestCase {

    func testAbortedBeforeFetchWhenGenerationStale() async {
        let converter = AzooKeyConverter()
        converter.setLiveGeneration(1)
        converter.setLiveGeneration(2)
        let outcome = await converter.requestCandidatesWhileTyping(
            generation: 1,
            hiragana: "かんじ",
            leftSideContext: nil,
            options: .default
        )
        XCTAssertEqual(outcome, .abortedBeforeFetch)
    }

    func testCommitPurgesCachedReading() {
        let converter = AzooKeyConverter()
        let candidates = converter.requestCandidates(
            hiragana: "てすと",
            leftSideContext: nil,
            richCandidates: true
        )
        guard let text = candidates.first?.text else {
            XCTFail("expected at least one candidate")
            return
        }
        XCTAssertNotNil(
            converter.peekCachedCandidates(hiragana: "てすと", leftSideContext: nil, richCandidates: true)
        )
        converter.commit(reading: "てすと", text: text)
        XCTAssertNil(
            converter.peekCachedCandidates(hiragana: "てすと", leftSideContext: nil, richCandidates: true)
        )
    }
}
