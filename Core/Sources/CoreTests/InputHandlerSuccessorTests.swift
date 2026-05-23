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
        handler.db.recordNounBigram(prev: "東京", input: "が", output: "が")
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
        handler.db.recordNounBigram(prev: "東京", input: "が", output: "が")
        handler.leftSideContext = "今日は東京に"
        let showResult = type(chars: "g", base: "g")
        guard case .show(let candidates, _, _, _, _) = showResult.candidateAction else {
            XCTFail("文脈から prev を取って候補表示: \(showResult.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("が"))
    }

    func testSuccessorSpaceConfirmsNounBigram() {
        handler.db.recordNounBigram(prev: "東京", input: "が", output: "が")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        type(chars: "g", base: "g")
        let result = press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertTrue(result.consumed)
        XCTAssertTrue(client.inserted.contains("が"), "bigram 候補が挿入されるはず")
        assertDismiss(result.candidateAction)
    }

    func testSuccessorEscapeDismisses() {
        handler.db.recordNounBigram(prev: "東京", input: "が", output: "が")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        type(chars: "g", base: "g")
        let result = press(keyCode: 53, candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertTrue(result.consumed)
        assertDismiss(result.candidateAction)
    }

    func testSuccessorUnmatchedKeyFallsThroughToNormalCompose() {
        handler.db.recordNounBigram(prev: "東京", input: "が", output: "が")
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
        handler.db.recordNounBigram(prev: "東京", input: "が", output: "が")
        handler.db.recordNounBigram(prev: "が", input: "すき", output: "好き")

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
        handler.db.recordNounBigram(prev: "東京", input: "が", output: "が")
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
        handler.db.recordNounBigram(prev: "東京", input: "が", output: "が")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        type(chars: "g", base: "g")
        let result = press(keyCode: 125, candidateVisible: true, selectedRow: 0, selectedText: "が")
        guard case .selectNext = result.candidateAction else {
            XCTFail("↓ は .selectNext を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorRomajiUniqueFiltersAndConfirmWithSpace() {
        handler.db.recordNounBigram(prev: "東京", input: "が", output: "が")
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
        handler.db.recordNounBigram(prev: "東京", input: "に", output: "に")
        handler.db.recordNounBigram(prev: "東京", input: "の", output: "の")
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
        handler.db.recordNounBigram(prev: "東京", input: "たわー", output: "タワー")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let result = type(chars: "t", base: "t")
        guard case .show(let candidates, _, _, _, _) = result.candidateAction else {
            XCTFail("1打目で .show: \(result.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("タワー"))
    }

    func testSuccessorAfterKatakanaCommit() {
        handler.db.recordNounBigram(prev: "コーヒー", input: "しょっぷ", output: "ショップ")
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
        for _ in 0..<3 { handler.db.recordNounBigram(prev: "東京", input: "さいきん", output: "最近") }
        handler.db.recordNounBigram(prev: "東京", input: "さらに", output: "さらに")
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
        handler.db.recordNounBigram(prev: "東京", input: "が", output: "が")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        type(chars: "g", base: "g")
        let result = type(chars: "z", base: "z", candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "gz", "「g」→「z」が通常組成（pendingRomaji: gz）に入るはず")
    }

    func testSuccessorWithHiraganaBigramAfterCommit() {
        handler.db.recordNounBigram(prev: "おつかれ", input: "です", output: "です")
        typeRomaji("otsukare")
        press(keyCode: 36)
        let result = type(chars: "d", base: "d")
        guard case .show(let candidates, _, _, _, _) = result.candidateAction else {
            XCTFail("lastCommittedOutput フォールバックで候補表示: \(result.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("です"))
    }

    func testSuccessorNKeyShowsBothNiAndNo() {
        handler.db.recordNounBigram(prev: "東京", input: "に", output: "に")
        handler.db.recordNounBigram(prev: "東京", input: "の", output: "の")
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
        for _ in 0..<3 { handler.db.recordNounBigram(prev: "東京", input: "の", output: "の") }
        handler.db.recordNounBigram(prev: "東京", input: "に", output: "に")
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
        handler.db.recordNounBigram(
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
}
