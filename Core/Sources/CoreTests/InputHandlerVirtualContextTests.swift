import XCTest
@testable import KeynacoCore

final class InputHandlerVirtualContextTests: InputHandlerTestCase {

    // MARK: - VirtualHistoryExtractor

    func testExtractEmptyAfterSentenceTerminator() {
        XCTAssertEqual(VirtualHistoryExtractor.extract(from: "こんにちは。"), [])
    }

    func testExtractSingleTokenWithoutDelimiter() {
        XCTAssertEqual(VirtualHistoryExtractor.extract(from: "昨日は東京に"), ["昨日は東京に"])
    }

    func testExtractAfterComma() {
        XCTAssertEqual(VirtualHistoryExtractor.extract(from: "昨日、東京に"), ["昨日", "東京に"])
    }

    func testExtractEnglishWords() {
        XCTAssertEqual(VirtualHistoryExtractor.extract(from: "Hello world"), ["Hello", "world"])
    }

    // MARK: - Accessors

    func testLastCommittedOutputFallsBackToVirtual() {
        handler.virtualHistoryPrefix = ["東京"]
        XCTAssertEqual(handler.lastCommittedOutput, "東京")
    }

    func testCommittedUsesVirtualWhenSingleCommitted() {
        handler.committedHistory = ["昨日"]
        handler.virtualHistoryPrefix = ["東京"]
        XCTAssertEqual(handler.lastCommittedOutput, "昨日")
        XCTAssertEqual(handler.committedHistory.count, 1)
    }

    func testVirtualIgnoredWhenCommittedHistoryHasTwoOrMore() {
        handler.committedHistory = ["昨日", "は"]
        handler.virtualHistoryPrefix = ["東京"]
        XCTAssertEqual(handler.lastCommittedOutput, "は")
        XCTAssertEqual(handler.mostRecentContentWords(n: 2), ["昨日"])
    }

    // MARK: - Noun-bigram prediction

    func testSuggestSuccessorsUsesVirtualNounBigram() {
        handler.committedHistory = []
        handler.virtualHistoryPrefix = ["東京"]
        seedNounBigramPrediction(prev: "東京", input: "に", output: "に")
        _ = handler.suggestSuccessors()
        XCTAssertTrue(handler.isSuccessorMode)
        XCTAssertTrue(handler.pendingSuccessorCandidates.contains("に"))
    }

    func testPendingPreviewUsesVirtualNounBigram() {
        handler.committedHistory = []
        handler.virtualHistoryPrefix = ["東京"]
        seedNounBigramPrediction(prev: "東京", input: "から", output: "から")
        let action = handler.buildPendingCandidateList(pendingChar: "k", client: client)
        XCTAssertTrue(handler.isSuccessorMode)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("virtual 文脈で pending 先読み .show を返すはず: \(action)")
            return
        }
        XCTAssertTrue(candidates.contains("から"))
    }

    // MARK: - Learning isolation

    func testVirtualDoesNotRecordNounBigramOnCommit() {
        handler.virtualHistoryPrefix = ["東京"]
        handler.committedHistory = []
        typeRomaji("ik")
        press(keyCode: KeyCode.enter)
        XCTAssertTrue(handler.db.fetchNounBigramTop(prev: "東京").isEmpty,
                      "virtual のみのとき確定で noun_bigram が記録されないはず")
    }
}
