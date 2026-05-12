import XCTest
@testable import KeynacoCore

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
        XCTAssertTrue(hist.contains("あい"), "Enter 確定後にひらがなが履歴として記録されるはず")
    }

    func testHistoryRecordedAfterCandidateSelectionAndEnter() {
        type(chars: "a", base: "a")
        press(keyCode: 36, candidateVisible: true, selectedRow: 1, selectedText: "阿")
        let hist = handler.db.fetchHistoryExact(reading: "あ")
        XCTAssertTrue(hist.contains("阿"), "候補選択→Enter 確定後に変換結果が履歴として記録されるはず")
    }

    func testConversionHistoryBoostsNextConversion() {
        typeRomaji("tanoshii")
        press(keyCode: 36, candidateVisible: true, selectedText: "楽しい")
        press(keyCode: 53)  // Escape でSuccessor モードを解除
        typeRomaji("tanoshii")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, let historyEnd, _, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.prefix(historyEnd).contains("楽しい"),
                      "前回確定した「楽しい」が次回変換で履歴候補として現れるはず")
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

    /// 組成空で Backspace したとき、`lastConfirmedContext` に応じて bi-gram にペナルティする。
    func testPenalizeAllRemovesBigramWhenBackspaceAfterSyntheticConfirm() {
        handler.db.testInsertBigram(prev: "東京", input: "きょう", output: "今日", count: 1, usedAt: 0, isPreset: false)
        handler.lastConfirmedContext = LastConfirmedContext(
            input: "きょう", output: "今日",
            prev1: "東京", prev2: nil, skipPrevs: [], fullReading: nil
        )
        let (_, _) = press(keyCode: 51)
        XCTAssertNil(handler.lastConfirmedContext)
        XCTAssertNil(
            handler.db.fetchAllBigram().first { $0.prev == "東京" && $0.output == "今日" },
            "count=1 をペナルティして削除されるはず"
        )
    }

    func testPenalizeAllSkipsPresetBigramOnBackspace() {
        handler.db.testInsertBigram(prev: "東京", input: "きょう", output: "今日", count: 1, usedAt: 0, isPreset: true)
        handler.lastConfirmedContext = LastConfirmedContext(
            input: "きょう", output: "今日",
            prev1: "東京", prev2: nil, skipPrevs: [], fullReading: nil
        )
        _ = press(keyCode: 51)
        let row = handler.db.fetchAllBigram().first { $0.prev == "東京" && $0.output == "今日" }
        XCTAssertEqual(row?.count, 1, "プリセット行はペナルティ対象外")
    }

    func testSecondBackspaceDoesNotPenalizeAgain() {
        handler.db.record(input: "あ", output: "阿")
        handler.lastConfirmedContext = LastConfirmedContext(
            input: "あ", output: "阿",
            prev1: nil, prev2: nil, skipPrevs: [], fullReading: nil
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
        press(keyCode: 53)  // Escape でSuccessor モード解除
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

    func testPeriodViaRomajiMappingClearsCommittedHistory() {
        // 「今日」を確定して history を積む
        typeRomaji("kyou")
        press(keyCode: 36, candidateVisible: true, selectedText: "今日")
        press(keyCode: 53)
        XCTAssertFalse(handler.committedHistory.isEmpty)

        // "." → "。"（handlePunctuation 経由）→ clears
        type(chars: ".", base: ".")
        XCTAssertTrue(handler.committedHistory.isEmpty, "「.」→「。」変換で committedHistory がクリアされるはず")
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
}
