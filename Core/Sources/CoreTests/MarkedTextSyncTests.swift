import XCTest
@testable import KeynacoCore

final class MarkedTextSyncTests: XCTestCase {

    func testCandidateOnly_bracketMode() {
        XCTAssertTrue(MarkedTextSync.needsCandidateOnly(
            isBracketMode: true, candidateVisible: true, composedHiragana: ""))
        XCTAssertEqual(MarkedTextSync.resolve(
            isBracketMode: true,
            candidateVisible: true,
            isExplicitlySelected: false,
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
            isExplicitlySelected: false,
            composedHiragana: "",
            pendingRomaji: "",
            composingText: "",
            selectedCandidate: "東京"
        ), "東京")
    }

    func testComposing_usesSelectedPlusPendingWhenExplicit() {
        XCTAssertFalse(MarkedTextSync.needsCandidateOnly(
            isBracketMode: false, candidateVisible: true, composedHiragana: "かん"))
        XCTAssertEqual(MarkedTextSync.resolve(
            isBracketMode: false,
            candidateVisible: true,
            isExplicitlySelected: true,
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
            isExplicitlySelected: false,
            composedHiragana: "かんじ",
            pendingRomaji: "",
            composingText: "かんじ",
            selectedCandidate: nil
        ), "かんじ")
    }

    func testWhileTypingSuggest_keepsComposingHiragana() {
        XCTAssertEqual(MarkedTextSync.resolve(
            isBracketMode: false,
            candidateVisible: true,
            isExplicitlySelected: false,
            composedHiragana: "かんじ",
            pendingRomaji: "",
            composingText: "かんじ",
            selectedCandidate: "漢字"
        ), "かんじ")
    }

    /// passive 候補表示中も pending ローマ字尾を marked に出す。
    /// commit（Enter）と marked を一致させる（`.hidden` フォールバックで finalizedText 確定される）。
    /// 修正前は `かんj` の `j` を隠して `かん` を marked にしとったが、ri- + n 型の食い違い（marked "りー" / commit "りーん"）を招くため撤去。
    func testPassiveCompose_showsTrailingRomajiTail() {
        XCTAssertEqual(MarkedTextSync.resolve(
            isBracketMode: false,
            candidateVisible: true,
            isExplicitlySelected: false,
            composedHiragana: "かん",
            pendingRomaji: "j",
            composingText: "かんj",
            selectedCandidate: "漢字"
        ), "かんj")
    }

    func testHiddenCandidate_showsTrailingRomajiTail() {
        XCTAssertEqual(MarkedTextSync.resolve(
            isBracketMode: false,
            candidateVisible: false,
            isExplicitlySelected: false,
            composedHiragana: "あい",
            pendingRomaji: "s",
            composingText: "あいs",
            selectedCandidate: nil
        ), "あいs")
    }

    func testPassiveCompose_keepsAsciiWordPending() {
        XCTAssertEqual(MarkedTextSync.resolve(
            isBracketMode: false,
            candidateVisible: true,
            isExplicitlySelected: false,
            composedHiragana: "GitH",
            pendingRomaji: "ub",
            composingText: "GitHub",
            selectedCandidate: nil
        ), "GitHub")
    }

    func testExplicitSelection_followsCandidate() {
        XCTAssertEqual(MarkedTextSync.resolve(
            isBracketMode: false,
            candidateVisible: true,
            isExplicitlySelected: true,
            composedHiragana: "かんじ",
            pendingRomaji: "",
            composingText: "かんじ",
            selectedCandidate: "漢字"
        ), "漢字")
    }
}
