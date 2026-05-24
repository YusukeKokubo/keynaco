import XCTest
@testable import KeynacoCore

// See: docs/domain/states.md#successor-モード
// See: docs/domain/scenarios.md (S-03)

final class InputHandlerSuccessorTests: InputHandlerTestCase {

    // MARK: - extractNounFromContext

    func testExtractNounFromContext_kanjiAtEnd() {
        XCTAssertEqual(InputHandler.extractNounFromContext("今日は東京に"), "東京")
    }

    func testExtractNounFromContext_katakanaAtEnd() {
        XCTAssertEqual(InputHandler.extractNounFromContext("飲みにコーヒー"), "コーヒー")
    }

    func testExtractNounFromContext_empty() {
        XCTAssertNil(InputHandler.extractNounFromContext(""))
    }

    func testExtractNounFromContext_hiraganaOnly() {
        XCTAssertNil(InputHandler.extractNounFromContext("おつかれ"))
    }

    // MARK: - Successor 候補（組成空 + 1 打目トリガー）

    func testSuccessorShowsOnFirstKeyAfterCommit() {
        recordFetchableContentBigram(prev: "東京", input: "が", output: "が")
        typeRomaji("tokyo")
        let commitResult = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        assertDismiss(commitResult.candidateAction, "確定直後は候補を出さない")
        let showResult = type(chars: "g", base: "g")
        guard case .show(let candidates, _, _, _, _) = showResult.candidateAction else {
            XCTFail("1打目で候補表示: \(showResult.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("が"), "「g」で「が」を含むはず")
    }

    func testSuccessorUsesLeftSideContext() {
        recordFetchableContentBigram(prev: "東京", input: "が", output: "が")
        handler.leftSideContext = "今日は東京に"
        let showResult = type(chars: "g", base: "g")
        guard case .show(let candidates, _, _, _, _) = showResult.candidateAction else {
            XCTFail("文脈から prev を取って候補表示: \(showResult.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("が"))
    }

    func testSuccessorSpaceConfirmsNounBigram() {
        recordFetchableContentBigram(prev: "東京", input: "が", output: "が")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        type(chars: "g", base: "g")
        let result = press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertTrue(result.consumed)
        XCTAssertTrue(client.inserted.contains("が"), "bigram 候補が挿入されるはず")
        assertDismiss(result.candidateAction)
    }

    func testSuccessorEscapeDismisses() {
        recordFetchableContentBigram(prev: "東京", input: "が", output: "が")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        type(chars: "g", base: "g")
        let result = press(keyCode: 53, candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertTrue(result.consumed)
        assertDismiss(result.candidateAction)
    }

    func testSuccessorUnmatchedKeyFallsThroughToNormalCompose() {
        recordFetchableContentBigram(prev: "東京", input: "が", output: "が")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let result = type(chars: "q", base: "q")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "q", "候補なしキーは通常組成")
    }

    func testSuccessorHistoryPrefixWhenNoBigram() {
        handler.db.recordPrefixes(reading: "がっこう", output: "学校")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let showResult = type(chars: "g", base: "g")
        guard case .show(let candidates, _, _, _, _) = showResult.candidateAction else {
            XCTFail("履歴前方一致で候補表示: \(showResult.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("学校"))
    }

    func testSuccessorChain() {
        recordFetchableContentBigram(prev: "東京", input: "が", output: "が")
        recordFetchableContentBigram(prev: "が", input: "すき", output: "好き")

        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")

        let showResult = type(chars: "g", base: "g")
        guard case .show(let shown, _, _, _, _) = showResult.candidateAction else {
            XCTFail(".show を返すはず: \(showResult.candidateAction)"); return
        }
        XCTAssertTrue(shown.contains("が"))

        press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertTrue(client.inserted.contains("が"))

        // ひらがな末尾（が）確定後は Successor チェーンしない → 通常組成
        let chainResult = type(chars: "s", base: "s")
        XCTAssertEqual(client.markedText, "s", "格助詞確定後は通常組成")
        guard case .dismiss = chainResult.candidateAction else {
            XCTFail("「が」確定後は Successor 候補を出さない: \(chainResult.candidateAction)"); return
        }
    }

    func testBackspaceAfterCommitClearsSuccessorEligible() {
        recordFetchableContentBigram(prev: "東京", input: "が", output: "が")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.successorEligible)
        _ = press(keyCode: KeyCode.backspace)
        XCTAssertFalse(handler.successorEligible, "確定直後 Backspace で successorEligible をクリア")
        let result = type(chars: "g", base: "g")
        XCTAssertEqual(client.markedText, "g", "Backspace 後は Successor ではなく通常組成")
        guard case .dismiss = result.candidateAction else {
            XCTFail("Backspace 後は Successor 候補を出さない: \(result.candidateAction)"); return
        }
    }

    func testSuccessorArrowNavigates() {
        recordFetchableContentBigram(prev: "東京", input: "が", output: "が")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        type(chars: "g", base: "g")
        let result = press(keyCode: 125, candidateVisible: true, selectedRow: 0, selectedText: "が")
        guard case .selectNext = result.candidateAction else {
            XCTFail("↓ は .selectNext を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorRomajiUniqueFiltersAndConfirmWithSpace() {
        recordFetchableContentBigram(prev: "東京", input: "が", output: "が")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let filterResult = type(chars: "g", base: "g")
        guard case .show(let candidates, _, _, _, _) = filterResult.candidateAction else {
            XCTFail("絞り込み後は .show を返すはず: \(filterResult.candidateAction)"); return
        }
        XCTAssertEqual(candidates, ["が"])
        let confirmResult = press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertTrue(client.inserted.contains("が"))
        assertDismiss(confirmResult.candidateAction)
    }

    func testSuccessorRomajiAmbiguousFilters() {
        recordFetchableContentBigram(prev: "東京", input: "に", output: "に")
        recordFetchableContentBigram(prev: "東京", input: "の", output: "の")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let result = type(chars: "n", base: "n")
        guard case .show(let candidates, _, _, _, _) = result.candidateAction else {
            XCTFail("絞り込み後は .show を返すはず: \(result.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("に") && candidates.contains("の"), "に・の が候補に含まれるはず: \(candidates)")
        XCTAssertFalse(candidates.contains("が"))
    }

    func testSuccessorAfterKanjiCommit() {
        recordFetchableContentBigram(prev: "東京", input: "たわー", output: "タワー")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let result = type(chars: "t", base: "t")
        guard case .show(let candidates, _, _, _, _) = result.candidateAction else {
            XCTFail("1打目で .show: \(result.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("タワー"))
    }

    func testSuccessorAfterKatakanaCommit() {
        recordFetchableContentBigram(prev: "コーヒー", input: "しょっぷ", output: "ショップ")
        typeRomaji("koohii")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "コーヒー")
        let result = type(chars: "s", base: "s")
        guard case .show(let candidates, _, _, _, _) = result.candidateAction else {
            XCTFail("1打目で .show: \(result.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("ショップ"))
    }

    func testSuccessorNoCandidatesAfterHiraganaCommitWithoutBigram() {
        typeRomaji("ta")
        press(keyCode: 36)
        let result = type(chars: "n", base: "n")
        XCTAssertEqual(client.markedText, "n", "bigram/履歴なしなら通常組成")
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorNoCandidatesAfterSymbolCommit() {
        typeRomaji("a")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "？")
        let result = type(chars: "n", base: "n")
        XCTAssertEqual(client.markedText, "n")
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorBigramOrderedByFrequency() {
        for _ in 0..<3 { recordFetchableContentBigram(prev: "東京", input: "さいきん", output: "最近") }
        recordFetchableContentBigram(prev: "東京", input: "さらに", output: "さらに")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let showResult = type(chars: "s", base: "s")
        guard case .show(let candidates, _, _, _, _) = showResult.candidateAction else {
            XCTFail("1打後は .show を返すはず: \(showResult.candidateAction)"); return
        }
        let idxSaikin = candidates.firstIndex(of: "最近")
        let idxSarani = candidates.firstIndex(of: "さらに")
        XCTAssertNotNil(idxSaikin)
        XCTAssertNotNil(idxSarani)
        if let i = idxSaikin, let s = idxSarani {
            XCTAssertLessThan(i, s, "頻度の高い bi-gram 候補が先頭")
        }
    }

    func testSuccessorBufferedKeyFallthroughOnSecondKeyMismatch() {
        recordFetchableContentBigram(prev: "東京", input: "が", output: "が")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        type(chars: "g", base: "g")
        let result = type(chars: "z", base: "z", candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "gz", "「g」→「z」が通常組成（pendingRomaji: gz）に入るはず")
    }

    func testSuccessorWithHiraganaBigramAfterCommit() {
        recordFetchableContentBigram(prev: "おつかれ", input: "です", output: "です")
        typeRomaji("otsukare")
        press(keyCode: 36)
        let result = type(chars: "d", base: "d")
        guard case .show(let candidates, _, _, _, _) = result.candidateAction else {
            XCTFail("lastCommittedOutput フォールバックで候補表示: \(result.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("です"))
    }

    func testSuccessorNKeyShowsBothNiAndNo() {
        recordFetchableContentBigram(prev: "東京", input: "に", output: "に")
        recordFetchableContentBigram(prev: "東京", input: "の", output: "の")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let result = type(chars: "n", base: "n")
        guard case .show(let candidates, _, _, _, _) = result.candidateAction else {
            XCTFail("n → .show を返すはず: \(result.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("に") && candidates.contains("の"))
        XCTAssertFalse(candidates.contains("が"))
    }

    func testSuccessorNKeyKanaArrayOrderPreserved() {
        for _ in 0..<3 { recordFetchableContentBigram(prev: "東京", input: "の", output: "の") }
        recordFetchableContentBigram(prev: "東京", input: "に", output: "に")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let result = type(chars: "n", base: "n")
        guard case .show(let candidates, _, _, _, _) = result.candidateAction else {
            XCTFail(".show を返すはず"); return
        }
        let idxNi = candidates.firstIndex(of: "に")
        let idxNo = candidates.firstIndex(of: "の")
        XCTAssertNotNil(idxNi)
        XCTAssertNotNil(idxNo)
        if let ni = idxNi, let n = idxNo {
            XCTAssertLessThan(ni, n, "kana 配列順（に が の より前）で表示されるはず")
        }
    }

    func testSuccessorPrefixSplit_longBigramOnFirstKey() {
        recordFetchableContentBigram(
            prev: "東京",
            input: "かいぎにしゅっせきする",
            output: "会議に出席する"
        )
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let showResult = type(chars: "k", base: "k")
        guard case .show(let candidates, _, _, _, _) = showResult.candidateAction else {
            XCTFail("1 打目で .show: \(showResult.candidateAction)"); return
        }
        XCTAssertEqual(candidates, ["会議に出席する"])
    }

    // MARK: - Successor 多打絞り込み

    func testSuccessorFiltersOnSecondKey() {
        recordFetchableContentBigram(prev: "東京", input: "かいぎ", output: "会議")
        recordFetchableContentBigram(prev: "東京", input: "きょう", output: "今日")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let showResult = type(chars: "k", base: "k")
        guard case .show(let initial, _, _, _, _) = showResult.candidateAction else {
            XCTFail("1 打目で .show: \(showResult.candidateAction)"); return
        }
        XCTAssertTrue(initial.contains("会議") && initial.contains("今日"))

        let filterResult = type(chars: "a", base: "a", candidateVisible: true, selectedRow: 0, selectedText: initial[0])
        guard case .replaceCandidates(let filtered) = filterResult.candidateAction else {
            XCTFail("2 打目で .replaceCandidates: \(filterResult.candidateAction)"); return
        }
        XCTAssertEqual(filtered, ["会議"])
        XCTAssertEqual(client.markedText, "か")
    }

    func testSuccessorFiltersMultiSyllable() {
        recordFetchableContentBigram(prev: "東京", input: "かに", output: "確認")
        recordFetchableContentBigram(prev: "東京", input: "かい", output: "会議")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        type(chars: "k", base: "k")
        type(chars: "a", base: "a", candidateVisible: true, selectedRow: 0, selectedText: "会議")
        type(chars: "n", base: "n", candidateVisible: true, selectedRow: 0, selectedText: "会議")
        let filterResult = type(chars: "i", base: "i", candidateVisible: true, selectedRow: 0, selectedText: "会議")
        guard case .replaceCandidates(let filtered) = filterResult.candidateAction else {
            XCTFail("4 打目で .replaceCandidates: \(filterResult.candidateAction)"); return
        }
        XCTAssertEqual(filtered, ["確認"])
        XCTAssertEqual(handler.successorBufferedRomaji, "kani")
    }

    func testSuccessorZeroCandidatesFallsBackToNormalCompose() {
        recordFetchableContentBigram(prev: "東京", input: "かい", output: "会議")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        type(chars: "k", base: "k")
        type(chars: "a", base: "a", candidateVisible: true, selectedRow: 0, selectedText: "会議")
        type(chars: "k", base: "k", candidateVisible: true, selectedRow: 0, selectedText: "会議")
        let result = type(chars: "u", base: "u", candidateVisible: true, selectedRow: 0, selectedText: "会議")
        guard case .show = result.candidateAction else {
            XCTFail("候補ゼロ後は通常組成の .show: \(result.candidateAction)"); return
        }
        XCTAssertEqual(handler.state.composedHiragana, "かく")
        XCTAssertNil(handler.successorBufferedRomaji)
    }

    func testSuccessorIncompleteSyllableKeepsCandidates() {
        recordFetchableContentBigram(prev: "東京", input: "し", output: "試")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let showResult = type(chars: "s", base: "s")
        guard case .show = showResult.candidateAction else {
            XCTFail("1 打目で .show"); return
        }
        let waitResult = type(chars: "h", base: "h", candidateVisible: true, selectedRow: 0, selectedText: "試")
        guard case .none = waitResult.candidateAction else {
            XCTFail("未確定音節 \"sh\" は .none: \(waitResult.candidateAction)"); return
        }
        XCTAssertEqual(handler.successorBufferedRomaji, "sh")
    }
}
