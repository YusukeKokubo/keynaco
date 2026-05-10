import XCTest
@testable import KeynacoCore

final class CompositionStateTests: XCTestCase {

    // MARK: - composingText

    func testComposingTextCombinesHiraganaAndPending() {
        var s = CompositionState()
        _ = s.addRomaji("k")
        XCTAssertEqual(s.composingText, "k")
        _ = s.addRomaji("a")
        XCTAssertEqual(s.composingText, "か")
    }

    // MARK: - addRomaji

    func testAddRomajiSingleVowel() {
        var s = CompositionState()
        let needsRefresh = s.addRomaji("a")
        XCTAssertEqual(s.composedHiragana, "あ")
        XCTAssertEqual(s.pendingRomaji, "")
        XCTAssertFalse(needsRefresh, "1文字では候補リフレッシュ不要")
    }

    func testAddRomajiConsonantThenVowel() {
        var s = CompositionState()
        XCTAssertFalse(s.addRomaji("k"))
        XCTAssertEqual(s.pendingRomaji, "k")
        XCTAssertFalse(s.addRomaji("a"))
        XCTAssertEqual(s.composedHiragana, "か")
        XCTAssertEqual(s.pendingRomaji, "")
    }

    func testAddRomajiReturnsTrueWhenTwoOrMoreHiragana() {
        var s = CompositionState()
        _ = s.addRomaji("a")
        let needsRefresh = s.addRomaji("i")
        XCTAssertTrue(needsRefresh, "2文字以上で候補リフレッシュ必要")
        XCTAssertEqual(s.composedHiragana, "あい")
    }

    func testAddRomajiSokuon() {
        var s = CompositionState()
        _ = s.addRomaji("k")
        _ = s.addRomaji("k")
        _ = s.addRomaji("a")
        XCTAssertEqual(s.composedHiragana, "っか")
    }

    func testAddRomajiYouon() {
        var s = CompositionState()
        _ = s.addRomaji("k")
        _ = s.addRomaji("y")
        _ = s.addRomaji("o")
        _ = s.addRomaji("u")
        XCTAssertEqual(s.composedHiragana, "きょう")
        XCTAssertEqual(s.pendingRomaji, "")
    }

    func testAddRomajiDoubleNBeforeConsonantDoesNotCreateDoubleN() {
        var s = CompositionState()
        "hennkannkouho".forEach { _ = s.addRomaji(String($0)) }
        XCTAssertEqual(s.composedHiragana, "へんかんこうほ")
        XCTAssertEqual(s.pendingRomaji, "")
    }

    func testAddRomajiNNBeforeVowelStillKeepsN() {
        var s = CompositionState()
        "kanna".forEach { _ = s.addRomaji(String($0)) }
        XCTAssertEqual(s.composedHiragana, "かんな")
        XCTAssertEqual(s.pendingRomaji, "")
    }

    func testAddRomajiNonRomajiCharFlushesConsonant() {
        var s = CompositionState()
        _ = s.addRomaji("k")
        _ = s.addRomaji(".")
        // "k" は forceFinalize でそのまま出力、"." も追加される
        XCTAssertEqual(s.composedHiragana, "k.")
        XCTAssertEqual(s.pendingRomaji, "")
    }

    // MARK: - backspace

    func testBackspaceRemovesPendingFirst() {
        var s = CompositionState()
        _ = s.addRomaji("k")
        let (handled, _) = s.backspace()
        XCTAssertTrue(handled)
        XCTAssertEqual(s.pendingRomaji, "")
        XCTAssertEqual(s.composedHiragana, "")
    }

    func testBackspaceRemovesHiraganaWhenNoPending() {
        var s = CompositionState()
        _ = s.addRomaji("a")
        _ = s.addRomaji("i")
        XCTAssertEqual(s.composedHiragana, "あい")
        let (handled, needsRefresh) = s.backspace()
        XCTAssertTrue(handled)
        XCTAssertEqual(s.composedHiragana, "あ")
        XCTAssertFalse(needsRefresh, "1文字ではリフレッシュ不要")
    }

    func testBackspaceReturnsFalseWhenEmpty() {
        var s = CompositionState()
        let (handled, _) = s.backspace()
        XCTAssertFalse(handled)
    }

    func testBackspaceNeedsRefreshWhenTwoOrMoreRemain() {
        var s = CompositionState()
        _ = s.addRomaji("a")
        _ = s.addRomaji("i")
        _ = s.addRomaji("u")
        let (_, needsRefresh) = s.backspace()
        XCTAssertTrue(needsRefresh)
        XCTAssertEqual(s.composedHiragana, "あい")
    }

    // MARK: - reset

    func testResetClearsState() {
        var s = CompositionState()
        _ = s.addRomaji("k")
        _ = s.addRomaji("a")
        let hadContent = s.reset()
        XCTAssertTrue(hadContent)
        XCTAssertEqual(s.composedHiragana, "")
        XCTAssertEqual(s.pendingRomaji, "")
        XCTAssertEqual(s.composingText, "")
    }

    func testResetReturnsFalseWhenEmpty() {
        var s = CompositionState()
        XCTAssertFalse(s.reset())
    }

    // MARK: - finalizedText

    func testFinalizedTextConvertsTrailingN() {
        var s = CompositionState()
        _ = s.addRomaji("k")
        _ = s.addRomaji("a")
        _ = s.addRomaji("n")
        XCTAssertEqual(s.finalizedText, "かん")
    }

    func testFinalizedTextWithNoPending() {
        var s = CompositionState()
        _ = s.addRomaji("a")
        XCTAssertEqual(s.finalizedText, "あ")
    }

    // MARK: - absorbPendingIntoComposed

    func testAbsorbPendingIntoComposedAfterNNDiscardsHiddenN() {
        var s = CompositionState()
        _ = s.addRomaji("n")
        _ = s.addRomaji("n")
        XCTAssertTrue(s.hiddenPendingN)
        XCTAssertEqual(s.composedHiragana, "ん")
        s.absorbPendingIntoComposed()
        XCTAssertEqual(s.composedHiragana, "ん")
        XCTAssertEqual(s.pendingRomaji, "")
        XCTAssertFalse(s.hiddenPendingN)
    }

    func testAbsorbPendingIntoComposedForceFinalizesWhenNotHidden() {
        var s = CompositionState()
        _ = s.addRomaji("k")
        _ = s.addRomaji("a")
        _ = s.addRomaji("n")
        XCTAssertFalse(s.hiddenPendingN)
        s.absorbPendingIntoComposed()
        XCTAssertEqual(s.composedHiragana, "かん")
        XCTAssertEqual(s.pendingRomaji, "")
    }

    // MARK: - isShiftInput

    func testIsShiftInput() {
        XCTAssertTrue(CompositionState.isShiftInput(characters: "A", baseCharacters: "a"))
        XCTAssertFalse(CompositionState.isShiftInput(characters: "a", baseCharacters: "a"))
    }
}
