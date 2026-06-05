import XCTest
@testable import KeynacoCore

final class MarkedTextSyncTests: XCTestCase {

    func testCandidateOnly_bracketMode() {
        XCTAssertTrue(MarkedTextSync.needsCandidateOnly(
            isBracketMode: true, candidateVisible: true, composedHiragana: ""))
        XCTAssertEqual(MarkedTextSync.resolve(
            isBracketMode: true,
            candidateVisible: true,
            composedHiragana: "",
            pendingRomaji: "",
            composingText: "",
            selectedCandidate: "．"
        ), "．")
    }

    func testCandidateOnly_emptyComposeWithCandidates() {
        XCTAssertTrue(MarkedTextSync.needsCandidateOnly(
            isBracketMode: false, candidateVisible: true, composedHiragana: ""))
        XCTAssertEqual(MarkedTextSync.resolve(
            isBracketMode: false,
            candidateVisible: true,
            composedHiragana: "",
            pendingRomaji: "",
            composingText: "",
            selectedCandidate: "東京"
        ), "東京")
    }

    func testComposing_usesSelectedPlusPending() {
        XCTAssertFalse(MarkedTextSync.needsCandidateOnly(
            isBracketMode: false, candidateVisible: true, composedHiragana: "かん"))
        XCTAssertEqual(MarkedTextSync.resolve(
            isBracketMode: false,
            candidateVisible: true,
            composedHiragana: "かん",
            pendingRomaji: "j",
            composingText: "かんj",
            selectedCandidate: "感"
        ), "感j")
    }

    func testNoCandidate_fallsBackToComposingText() {
        XCTAssertEqual(MarkedTextSync.resolve(
            isBracketMode: false,
            candidateVisible: false,
            composedHiragana: "かんじ",
            pendingRomaji: "",
            composingText: "かんじ",
            selectedCandidate: nil
        ), "かんじ")
    }

    func testComposingWithCandidates_usesSelectedPlusPending() {
        XCTAssertEqual(MarkedTextSync.resolve(
            isBracketMode: false,
            candidateVisible: true,
            composedHiragana: "かんじ",
            pendingRomaji: "",
            composingText: "かんじ",
            selectedCandidate: "漢字"
        ), "漢字")
    }
}
