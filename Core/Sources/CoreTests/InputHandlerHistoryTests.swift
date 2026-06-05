import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

// See: docs/domain/glossary.md#databasemanager
// See: docs/domain/glossary.md#lastcommittedoutput

final class InputHandlerHistoryTests: InputHandlerTestCase {

    // MARK: - 変換確定と履歴記録
    // See: docs/domain/glossary.md#databasemanager

    func testHistoryRecordedAfterEnterConfirmation() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        press(keyCode: 36)  // Enter → 確定
        let hist = handler.db.fetchHistoryExact(reading: "あい")
        XCTAssertTrue(hist.contains("あい"), "HiraganaPreferred 外のひらがな確定は履歴に記録する")
    }

    // MARK: - ひらがなパススルーの history 記録除外

    func testHiraganaPassthroughNotRecorded() {
        handler.db.recordPrefixes(reading: "は", output: "は")
        XCTAssertTrue(handler.db.fetchHistoryExact(reading: "は").isEmpty, "助詞パススルーは記録しない")
    }

    func testNonParticleHiraganaPassthroughIsRecorded() {
        // HiraganaPreferredBuiltins に含まれないひらがな語は記録する（「さん」「して」等）
        handler.db.recordPrefixes(reading: "して", output: "して")
        XCTAssertFalse(handler.db.fetchHistoryExact(reading: "して").isEmpty, "助詞以外のひらがなは記録する")
    }

    // MARK: - 格助詞トリム記録

    func testTrailingParticleTrimmedOnRecord() {
        // 格助詞「が」は trim される。reading も対応部分を除去
        handler.db.recordPrefixes(reading: "とうきょうが", output: "東京が")
        let exact = handler.db.fetchHistoryExact(reading: "とうきょう")
        XCTAssertTrue(exact.contains("東京"), "「とうきょう」→「東京」で記録されるはず")
        let withGa = handler.db.fetchHistoryExact(reading: "とうきょうが")
        XCTAssertTrue(withGa.isEmpty, "「とうきょうが」は記録されない")
    }

    func testNonParticleSuffixNotTrimmed() {
        // 活用語尾「る」「て」は格助詞でないので trim しない
        handler.db.recordPrefixes(reading: "でる", output: "出る")
        handler.db.recordPrefixes(reading: "おしえて", output: "教えて")
        XCTAssertFalse(handler.db.fetchHistoryExact(reading: "でる").isEmpty, "「出る」はそのまま記録")
        XCTAssertFalse(handler.db.fetchHistoryExact(reading: "おしえて").isEmpty, "「教えて」はそのまま記録")
    }

    func testTrimTrailingParticleHelper() {
        XCTAssertEqual(DatabaseManager.trimTrailingParticle("東京が"), "東京")
        XCTAssertEqual(DatabaseManager.trimTrailingParticle("何時に"), "何時")
        XCTAssertEqual(DatabaseManager.trimTrailingParticle("東京より"), "東京")
        XCTAssertNil(DatabaseManager.trimTrailingParticle("出る"))
        XCTAssertNil(DatabaseManager.trimTrailingParticle("教えて"))
        XCTAssertNil(DatabaseManager.trimTrailingParticle("東京"))
    }

    func testPrefixSearchHitsAfterParticleTrim() {
        handler.db.recordPrefixes(reading: "とうきょうが", output: "東京が")
        let results = handler.db.fetchHistoryScoredMerged(reading: "とうきょう")
        XCTAssertTrue(results.map(\.output).contains("東京"), "前方一致で「東京」がヒットするはず")
    }

    func testNonParticleEndingPreserved() {
        // 非格助詞末尾の output はそのまま記録
        handler.db.recordPrefixes(reading: "わたしたち", output: "私たち")
        let r = handler.db.fetchHistoryExact(reading: "わたしたち")
        XCTAssertTrue(r.contains("私たち"), "格助詞以外の末尾はそのまま記録")
    }

    func testHiraganaToKanjiIsRecorded() {
        handler.db.recordPrefixes(reading: "は", output: "葉")
        XCTAssertFalse(handler.db.fetchHistoryExact(reading: "は").isEmpty, "「は」→「葉」は変換なので記録する")
    }

    func testKatakanaOutputIsRecorded() {
        handler.db.recordPrefixes(reading: "ひらがな", output: "ヒラガナ")
        XCTAssertFalse(handler.db.fetchHistoryExact(reading: "ひらがな").isEmpty, "カタカナ変換は記録する")
    }

    func testHistoryRecordedAfterCandidateSelectionAndEnter() {
        type(chars: "a", base: "a")
        press(keyCode: 36, candidateVisible: true, selectedRow: 1, selectedText: "阿")
        let hist = handler.db.fetchHistoryExact(reading: "あ")
        XCTAssertTrue(hist.contains("阿"), "候補選択→Enter 確定後に変換結果が履歴として記録されるはず")
    }

    func testConversionHistoryBoostsNextConversion() {
        typeRomaji("toukyou")
        press(keyCode: 36, candidateVisible: true, selectedText: "東京")
        press(keyCode: 53)  // Escape で候補ウィンドウを閉じる
        typeRomaji("toukyou")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, let historyEnd, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.prefix(historyEnd).contains("東京"),
                      "前回確定した「東京」が次回変換で履歴候補として現れるはず")
    }

    // MARK: - 読み前方一致による履歴ヒット（recordPrefixes はフル読みのみ記録）
    // 前方一致検索は fetchHistoryScoredMerged の LIKE クエリが担う。
    // See: docs/domain/glossary.md#databasemanager

    func testPrefixRecord() {
        handler.db.recordPrefixes(reading: "とうきょう", output: "東京")

        XCTAssertEqual(handler.db.fetchHistoryExact(reading: "とうきょう"), ["東京"], "フル読みで exact ヒット")
        XCTAssertTrue(handler.db.fetchHistoryExact(reading: "とうきょ").isEmpty, "フル読み以外は exact ヒットしない")

        // LIKE 前方一致では候補が出る
        let merged = handler.db.fetchHistoryScoredMerged(reading: "とうきょ").map(\.output)
        XCTAssertTrue(merged.contains("東京"), "prefix LIKE で前方一致ヒット")
    }

    func testPrefixRecordSkipsASCII() {
        handler.db.recordPrefixes(reading: "github", output: "GitHub")

        XCTAssertEqual(handler.db.fetchHistoryExact(reading: "github"), ["GitHub"], "フル読みは記録される")
        XCTAssertTrue(handler.db.fetchHistoryExact(reading: "githu").isEmpty, "プレフィックスはexactヒットしない")
    }

    func testPrefixRecordViaCommit() {
        // 通常確定パスで recordPrefixes が呼ばれ、LIKE 検索で候補が出ることを確認
        typeRomaji("toukyou")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")

        // exact ではヒットしない
        XCTAssertTrue(handler.db.fetchHistoryExact(reading: "とうきょ").isEmpty, "prefix の exact ヒットは記録しない")
        // scoredMerged の LIKE パスでヒットする
        let merged = handler.db.fetchHistoryScoredMerged(reading: "とうきょ").map(\.output)
        XCTAssertTrue(merged.contains("東京"), "確定後、LIKE 前方一致で履歴ヒットするはず")
    }

    // MARK: - ネガティブフィードバック（確定直後 Backspace でカウント減算）
    // See: docs/domain/glossary.md#databasemanager

    func testNegativeFeedbackDecreasesCount() {
        // 事前に count=1 のエントリを作成
        handler.db.recordPrefixes(reading: "あ", output: "阿")

        // 確定（recordPrefixes が呼ばれ count=2）
        type(chars: "a", base: "a")
        press(keyCode: 36, candidateVisible: true, selectedRow: 1, selectedText: "阿")

        // 確定直後 Backspace → penalizeAll で history count -1 → 1
        press(keyCode: 51)

        let entries = handler.db.fetchAllHistory()
        let entry = entries.first(where: { $0.input == "あ" && $0.output == "阿" })
        XCTAssertNotNil(entry, "ペナルティ後もエントリが残るはず")
        XCTAssertEqual(entry?.count, 1, "penalizeAll で history のカウントが 1 減るはず")
    }

    func testNegativeFeedbackDeletesWhenCountReachesZero() {
        // 事前登録なし（count=0 から確定で count=1 になる）
        type(chars: "a", base: "a")
        press(keyCode: 36, candidateVisible: true, selectedRow: 1, selectedText: "阿")

        // 確定直後 Backspace → penalizeAll → count=0 → DELETE
        press(keyCode: 51)

        let hist = handler.db.fetchHistoryExact(reading: "あ")
        XCTAssertFalse(hist.contains("阿"), "count <= 0 でエントリが削除されるはず")
    }

    func testNegativeFeedbackNotTriggeredAfterOtherKey() {
        // 確定 (count=1)
        type(chars: "a", base: "a")
        press(keyCode: 36, candidateVisible: true, selectedRow: 1, selectedText: "阿")

        // 別キー打鍵 → lastConfirmedContext をクリア
        press(keyCode: 36)  // Enter（composingText なし → pass-through、かつ lastConfirmedContext = nil）

        // Backspace → penalize されない
        press(keyCode: 51)

        let hist = handler.db.fetchHistoryExact(reading: "あ")
        XCTAssertTrue(hist.contains("阿"), "別キー後の Backspace では penalize されないはず")
    }

    func testSecondBackspaceDoesNotPenalizeAgain() {
        handler.db.record(input: "あ", output: "阿")
        handler.lastConfirmedContext = LastConfirmedContext(
            input: "あ", output: "阿",
            fullReading: nil
        )
        _ = press(keyCode: 51)
        XCTAssertTrue(handler.db.fetchHistoryExact(reading: "あ").isEmpty)
        // 1 回目で lastConfirmedContext は消えている
        _ = press(keyCode: 51)
        // 二重にエラーにならなければよい（空のペナルティ呼び出しはしない）
    }

    // MARK: - 改行による committedHistory クリア

    func testEnterWithoutCompositionClearsCommittedHistory() {
        // 単語を確定して history を積む
        typeRomaji("kyou")
        press(keyCode: 36, candidateVisible: true, selectedText: "今日")
        press(keyCode: 53)  // Escape で候補ウィンドウを閉じる
        XCTAssertFalse(handler.committedHistory.isEmpty, "確定後は committedHistory に積まれているはず")

        // 組成なしで Enter（改行）→ クリアされる
        press(keyCode: 36)
        XCTAssertTrue(handler.committedHistory.isEmpty, "組成なし Enter で committedHistory がクリアされるはず")
    }

    func testEnterWithCompositionDoesNotClearCommittedHistory() {
        // 先に1語確定しておく
        typeRomaji("kyou")
        press(keyCode: 36, candidateVisible: true, selectedText: "今日")
        press(keyCode: 53)

        // 組成中に Enter → 組成を確定するだけで history はクリアしない
        typeRomaji("ha")
        press(keyCode: 36)
        XCTAssertFalse(handler.committedHistory.isEmpty, "組成あり Enter は文区切りではないので history を残すはず")
    }

    func testLastCommittedOutputNilAfterNewline() {
        // 「今日」を確定 → lastCommittedOutput が設定される
        typeRomaji("kyou")
        press(keyCode: 36, candidateVisible: true, selectedText: "今日")
        press(keyCode: 53)
        XCTAssertEqual(handler.lastCommittedOutput, "今日")

        // 組成なし Enter（改行）→ committedHistory がクリアされ lastCommittedOutput が nil になる
        press(keyCode: 36)
        XCTAssertNil(handler.lastCommittedOutput, "改行後は lastCommittedOutput が nil になるはず")
    }

    // MARK: - 句読点確定による committedHistory クリア

    func testPeriodDirectInputClearsCommittedHistory() {
        // 「今日」を確定して history を積む
        typeRomaji("kyou")
        press(keyCode: 36, candidateVisible: true, selectedText: "今日")
        press(keyCode: 53)
        XCTAssertFalse(handler.committedHistory.isEmpty)

        // 全角「。」を直接入力（handleNonAsciiChar 経由）→ sentenceTerminator でクリアされるはず
        type(chars: "。", base: "。")
        XCTAssertTrue(handler.committedHistory.isEmpty, "「。」直接入力で committedHistory がクリアされるはず")
    }

    func testPeriodViaBracketModeDoesNotImmediatelyClearCommittedHistory() {
        // 「今日」を確定して history を積む
        typeRomaji("kyou")
        press(keyCode: 36, candidateVisible: true, selectedText: "今日")
        press(keyCode: 53)
        XCTAssertFalse(handler.committedHistory.isEmpty)

        // "." → bracketOptions モード（markedText="。"）→ 確定前は history を残す
        type(chars: ".", base: ".")
        XCTAssertFalse(handler.committedHistory.isEmpty, "bracketOptions 表示中は history を残す")
    }

    func testCommaViaRomajiMappingDoesNotClearCommittedHistory() {
        // 「今日」を確定して history を積む
        typeRomaji("kyou")
        press(keyCode: 36, candidateVisible: true, selectedText: "今日")
        press(keyCode: 53)
        XCTAssertFalse(handler.committedHistory.isEmpty)

        // "," → "、"（読点は sentenceTerminator ではない）→ history は残る
        type(chars: ",", base: ",")
        XCTAssertFalse(handler.committedHistory.isEmpty, "「、」は文区切りではないので history を残すはず")
    }

    func testEnterInAsciiModeClearsCommittedHistory() {
        // 「今日」を確定して history を積む
        typeRomaji("kyou")
        press(keyCode: 36, candidateVisible: true, selectedText: "今日")
        press(keyCode: 53)
        XCTAssertFalse(handler.committedHistory.isEmpty)

        // 英数キー（keyCode 102）で ASCII モードへ
        press(keyCode: 102)
        XCTAssertTrue(InputHandler.isAsciiMode)

        // ASCII モード中に Enter → committedHistory がクリアされるはず
        press(keyCode: 36)
        XCTAssertTrue(handler.committedHistory.isEmpty, "ASCII モード中の Enter で committedHistory がクリアされるはず")
    }

    // MARK: - committedHistory（旧 SkipBigramTests より移設）

    func testCommittedHistoryCapAt5() {
        for i in 0..<6 {
            handler.commitText(text: "word\(i)", client: client)
        }
        XCTAssertEqual(handler.lastCommittedOutput, "word5")
        XCTAssertFalse(handler.committedHistory.contains("word0"))
        XCTAssertEqual(handler.committedHistory.count, 5)
    }

    func testSentenceTerminatorClearsHistory() {
        handler.commitText(text: "日本語", client: client)
        handler.commitText(text: "。", client: client)
        XCTAssertTrue(handler.committedHistory.isEmpty)
    }

    func testSentenceTerminatorClearsCommittedOutputs() {
        handler.commitText(text: "昨日", client: client)
        handler.commitText(text: "東京", client: client)
        XCTAssertEqual(handler.lastCommittedOutput, "東京")
        XCTAssertEqual(handler.committedHistory.count, 2)

        handler.commitText(text: "。", client: client)
        XCTAssertTrue(handler.committedHistory.isEmpty)
        XCTAssertNil(handler.lastCommittedOutput)
    }

    func testSentenceTerminatorPreventsCrossSentenceContext() {
        handler.commitText(text: "東京", client: client)
        handler.commitText(text: "。", client: client)
        handler.commitText(text: "大阪", client: client)
        XCTAssertEqual(handler.lastCommittedOutput, "大阪")
        XCTAssertEqual(handler.committedHistory, ["大阪"])
    }

    // MARK: - sessionTextBuffer

    func testSessionTextBufferNotResetBySentenceTerminator() {
        handler.commitText(text: "報告", client: client)
        handler.commitText(text: "。", client: client)
        XCTAssertTrue(handler.committedHistory.isEmpty)
        XCTAssertEqual(handler.sessionTextBuffer, "報告。")
    }

    func testSessionTextBufferTruncatesAt50() {
        let long = String(repeating: "あ", count: 40)
        handler.commitText(text: long, client: client)
        handler.commitText(text: String(repeating: "い", count: 20), client: client)
        XCTAssertEqual(handler.sessionTextBuffer.count, 50)
        XCTAssertTrue(handler.sessionTextBuffer.hasSuffix("い"))
    }

    func testSessionTextBufferSkipsReadingPunctuations() {
        handler.commitText(text: "東京", client: client)
        handler.commitText(text: "、", client: client)
        XCTAssertEqual(handler.sessionTextBuffer, "東京")
    }

    func testSessionTextBufferClearedOnAsciiEnter() {
        handler.commitText(text: "word", client: client)
        InputHandler.isAsciiMode = true
        press(keyCode: 36)
        XCTAssertEqual(handler.sessionTextBuffer, "")
    }

    func testSessionTextBufferClearedOnBareEnter() {
        handler.commitText(text: "報告", client: client)
        press(keyCode: 36)
        XCTAssertEqual(handler.sessionTextBuffer, "")
    }
}
