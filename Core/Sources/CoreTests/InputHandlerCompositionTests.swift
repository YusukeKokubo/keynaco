import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

// See: docs/domain/states.md#組成中
// See: docs/domain/scenarios.md#s-01-基本的なローマ字変換

final class InputHandlerCompositionTests: InputHandlerTestCase {

    // MARK: - ローマ字 → ひらがな変換
    // See: docs/domain/states.md#組成中
    // See: docs/domain/scenarios.md#s-01-基本的なローマ字変換

    func testSyncMarkedText_skipsIdenticalPayload() {
        handler.state.composedHiragana = "かんじ"
        handler.syncMarkedText(client: client)
        XCTAssertEqual(client.setMarkedTextCallCount, 1)
        handler.syncMarkedText(client: client)
        XCTAssertEqual(client.setMarkedTextCallCount, 1)
    }

    func testTypingKaMarksHiragana() {
        type(chars: "k", base: "k")
        XCTAssertEqual(client.markedText, "k")
        type(chars: "a", base: "a")
        XCTAssertEqual(client.markedText, "か")
    }

    func testTypingSingleVowel() {
        type(chars: "a", base: "a")
        XCTAssertEqual(client.markedText, "あ")
    }

    func testTypingTwoVowelsAutoShowsDictionaryCandidates() {
        type(chars: "a", base: "a")
        let (consumed, action) = type(chars: "i", base: "i")
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.markedText, "あい")
        guard let payload = action.showPayload else {
            XCTFail("辞書候補があればタイピング中も自動表示するはず: \(action)"); return
        }
        XCTAssertFalse(payload.candidates.isEmpty)
    }

    func testTypingShowsCandidatesWhenHistoryExists() {
        handler.db.record(input: "あい", output: "愛")
        type(chars: "a", base: "a")
        let (consumed, action) = type(chars: "i", base: "i")
        XCTAssertTrue(consumed)
        XCTAssertEqual(client.markedText, "あい")
        guard let payload = action.showPayload else {
            XCTFail("履歴ありなら自動表示するはず: \(action)"); return
        }
        XCTAssertTrue(payload.candidates.contains("あい"))
    }

    // MARK: - whileTyping 子音打鍵（母音限定候補の副作用対策）

    func testConsonantAfterWhileTypingDismissesCandidatesAndShowsPending() {
        // 履歴があれば defer モードでも候補窓が即時表示される。子音打鍵で dismiss する挙動の検証。
        handler.db.record(input: "あい", output: "愛")
        handler.deferAzooKeyWhileTyping = true
        type(chars: "a", base: "a")
        let (_, showAction) = type(chars: "i", base: "i")
        guard case .show = showAction else {
            XCTFail("あい で whileTyping 候補が出るはず: \(showAction)"); return
        }
        XCTAssertTrue(handler.candidateSession.isVisible)
        let (_, action) = type(chars: "k", base: "k")
        guard case .dismiss = action else {
            XCTFail("子音打鍵は .dismiss を返すはず: \(action)"); return
        }
        XCTAssertFalse(handler.candidateSession.isVisible)
        XCTAssertEqual(client.markedText, "あいk")
    }

    func testEnterAfterConsonantDismissCommitsFullComposition() {
        handler.db.record(input: "かんじ", output: "漢字")
        handler.deferAzooKeyWhileTyping = true
        typeRomaji("kanzi")
        XCTAssertTrue(handler.candidateSession.isVisible)
        type(chars: "b", base: "b")
        XCTAssertFalse(handler.candidateSession.isVisible)
        XCTAssertEqual(client.markedText, "かんじb")
        press(keyCode: KeyCode.enter)
        XCTAssertEqual(client.inserted.last, "かんじb")
    }

    func testEnterWithPassiveCandidateAndPendingCommitsFinalizedText() {
        handler.db.record(input: "あい", output: "愛")
        handler.deferAzooKeyWhileTyping = true
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        handler.state.pendingRomaji = "k"
        let ctx = handler.candidateSession.makeContext()
        XCTAssertTrue(ctx.isVisible)
        XCTAssertFalse(ctx.isExplicitlySelected)
        handleAndApply(keyCode: KeyCode.enter, candidate: ctx)
        XCTAssertEqual(client.inserted.last, "あいk")
    }

    func testEnterWithExplicitCandidateAndPendingStillCommitsSelection() {
        handler.deferAzooKeyWhileTyping = true
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        handler.state.pendingRomaji = "k"
        let ctx = CandidateContext(
            isVisible: true, selectedRow: 0, selectedText: "あい", isExplicitlySelected: true
        )
        handleAndApply(keyCode: KeyCode.enter, candidate: ctx)
        XCTAssertEqual(client.inserted.last, "あい")
    }

    // MARK: - Return で確定
    // See: docs/domain/states.md#組成中

    func testReturnCommitsComposing() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 36)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["あ"])
    }

    func testReturnWhenEmptyPassesThrough() {
        let result = press(keyCode: 36)
        XCTAssertFalse(result.consumed)
        XCTAssertTrue(client.inserted.isEmpty)
    }

    func testReturnWithSelectedCandidateCommitsCandidate() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 1, selectedText: "阿", isExplicitlySelected: true)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["阿"])
        guard case .dismiss = result.candidateAction else {
            XCTFail("確定後は .dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    // MARK: - Escape でリセット
    // See: docs/domain/states.md#組成中

    func testEscapeClearsComposing() {
        type(chars: "k", base: "k")
        XCTAssertEqual(client.markedText, "k")
        let result = press(keyCode: 53)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "")
        guard case .dismiss = result.candidateAction else {
            XCTFail("Escape は .dismiss を返すはず"); return
        }
    }

    func testEscapeWhenEmptyPassesThrough() {
        XCTAssertFalse(press(keyCode: 53).consumed)
    }

    // MARK: - Backspace
    // See: docs/domain/states.md#組成中

    func testBackspaceRemovesPendingRomaji() {
        type(chars: "k", base: "k")
        XCTAssertEqual(client.markedText, "k")
        let result = press(keyCode: 51)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "")
    }

    func testBackspaceRemovesHiragana() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        XCTAssertEqual(client.markedText, "あい")
        let result = press(keyCode: 51)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "あ")
    }

    func testBackspaceWhenEmptyPassesThrough() {
        XCTAssertFalse(press(keyCode: 51).consumed)
    }

    // MARK: - 確定後の再入力

    func testTypingAfterConfirmationStartsFreshComposition() {
        type(chars: "a", base: "a")
        press(keyCode: 36)
        XCTAssertEqual(client.inserted, ["あ"])
        type(chars: "i", base: "i")
        XCTAssertEqual(client.markedText, "い", "確定後は新しい組成が始まるはず")
        XCTAssertEqual(client.inserted, ["あ"], "追加挿入はないはず")
    }

    // MARK: - 長音符（ー）
    // See: docs/domain/scenarios.md#s-01-基本的なローマ字変換

    func testLongVowelMarkAppendsToComposition() {
        type(chars: "r", base: "r")
        type(chars: "a", base: "a")
        type(chars: "-", base: "-")
        XCTAssertEqual(client.markedText, "らー", "ハイフンが長音符「ー」に変換されるはず")
    }

    // MARK: - composedHiragana が空のときのスペース

    func testSpaceConsumesWithOnlyPendingRomaji() {
        type(chars: "k", base: "k")
        XCTAssertEqual(client.markedText, "k")
        let result = press(keyCode: KeyCode.space)
        XCTAssertTrue(result.consumed, "pending のみのとき Space は IME が消費しホストへ渡さないはず")
        XCTAssertEqual(client.markedText, "k", "組成は変化しないはず")
    }

    // MARK: - commitComposition（deactivateServer 相当）

    func testCommitCompositionFinalizesHiragana() {
        type(chars: "k", base: "k")
        type(chars: "a", base: "a")
        handler.commitComposition(client: client)
        XCTAssertEqual(client.inserted, ["か"])
    }

    func testCommitCompositionConvertsPendingN() {
        type(chars: "k", base: "k")
        type(chars: "a", base: "a")
        type(chars: "n", base: "n")
        handler.commitComposition(client: client)
        XCTAssertEqual(client.inserted, ["かん"])
    }

    func testCommitCompositionWhenEmptyDoesNothing() {
        handler.commitComposition(client: client)
        XCTAssertTrue(client.inserted.isEmpty)
    }

    func testCommitCompositionWithExplicitCandidateCommitsCandidate() {
        type(chars: "a", base: "a")
        let ctx = CandidateContext(isVisible: true, selectedRow: 1, selectedText: "阿", isExplicitlySelected: true)
        handler.commitComposition(client: client, candidate: ctx)
        XCTAssertEqual(client.inserted, ["阿"])
    }

    func testCommitCompositionWithRowZeroCommitsHiragana() {
        type(chars: "a", base: "a")
        let ctx = CandidateContext(isVisible: true, selectedRow: 0, selectedText: "あ")
        handler.commitComposition(client: client, candidate: ctx)
        XCTAssertEqual(client.inserted, ["あ"])
    }

    // MARK: - 自然な日本語入力シナリオ
    // See: docs/domain/scenarios.md#s-01-基本的なローマ字変換
    // See: docs/domain/glossary.md#pendinromaji

    func testSokuonProducesSmallTsu() {
        typeRomaji("kka")
        XCTAssertEqual(client.markedText, "っか")
    }

    func testSokuonMidWord() {
        typeRomaji("zasshi")
        XCTAssertEqual(client.markedText, "ざっし")
    }

    func testNAutoFinalizedBeforeConsonant() {
        typeRomaji("kanji")
        XCTAssertEqual(client.markedText, "かんじ")
    }

    func testNNShowsNWithoutPending() {
        typeRomaji("nn")
        XCTAssertEqual(client.markedText, "ん")
    }

    func testNNThenVowelFinalizesN() {
        typeRomaji("nnna")
        XCTAssertEqual(client.markedText, "んな")
    }

    func testKonnnaProducesKonna() {
        // "konnna": nn→ん、3つ目の n + na→な
        typeRomaji("konnna")
        XCTAssertEqual(client.markedText, "こんな")
    }

    func testKonnichiwa() {
        typeRomaji("konnnichiwa")
        XCTAssertEqual(client.markedText, "こんにちわ")
    }

    func testKonnyakuProducesKonyaku() {
        typeRomaji("konnyaku")
        XCTAssertEqual(client.markedText, "こんやく")
    }

    func testKonnnyakuProducesKonnyaku() {
        typeRomaji("konnnyaku")
        XCTAssertEqual(client.markedText, "こんにゃく")
    }

    func testNBeforeVowelDoesNotProduceN() {
        typeRomaji("na")
        XCTAssertEqual(client.markedText, "な")
    }

    func testYouonKyo() {
        typeRomaji("kyo")
        XCTAssertEqual(client.markedText, "きょ")
    }

    func testYouonSha() {
        typeRomaji("sha")
        XCTAssertEqual(client.markedText, "しゃ")
    }

    func testYouonChi() {
        typeRomaji("chi")
        XCTAssertEqual(client.markedText, "ち")
    }

    func testYouonTsu() {
        typeRomaji("tsu")
        XCTAssertEqual(client.markedText, "つ")
    }

    func testBackspaceOneByOneFromComposition() {
        typeRomaji("uta")
        XCTAssertEqual(client.markedText, "うた")
        press(keyCode: 51)
        XCTAssertEqual(client.markedText, "う")
        press(keyCode: 51)
        XCTAssertEqual(client.markedText, "")
    }

    func testVerbOkuriganaConversion() {
        typeRomaji("kaki")
        XCTAssertEqual(client.markedText, "かき")
        let (_, action) = press(keyCode: 49)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(payload.candidates.contains("書き"), "「書き」が候補に含まれるはず: \(candidates)")
    }
}
