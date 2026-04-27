import XCTest
@testable import keynaco

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
        guard case .show(let candidates, let historyEnd, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.prefix(historyEnd).contains("楽しい"),
                      "前回確定した「楽しい」が次回変換で履歴候補として現れるはず")
    }

    // MARK: - 読み省略パターンの自動学習（recordPrefixes）
    // See: docs/domain/glossary.md#databasemanager

    func testPrefixRecord() {
        // 5文字以上のひらがな読みを確定すると prefix も記録される
        // "とうきょう"(5文字) → フル + prefix 3件("とうきょ","とうき","とう")
        handler.db.recordPrefixes(reading: "とうきょう", output: "東京")

        XCTAssertEqual(handler.db.fetchHistoryExact(reading: "とうきょう"), ["東京"], "フル読みで exact ヒット")
        XCTAssertEqual(handler.db.fetchHistoryExact(reading: "とうきょ"),   ["東京"], "N-1 prefix で exact ヒット")
        XCTAssertEqual(handler.db.fetchHistoryExact(reading: "とうき"),     ["東京"], "N-2 prefix で exact ヒット")
        XCTAssertEqual(handler.db.fetchHistoryExact(reading: "とう"),       ["東京"], "N-3 prefix で exact ヒット")
        XCTAssertTrue(handler.db.fetchHistoryExact(reading: "と").isEmpty,  "1文字(len<2)は記録しない")
    }

    func testPrefixRecord3Chars() {
        // 3文字のひらがな読みを確定すると prefix も記録される
        // "ぜんぶ"(3文字) → フル + prefix 1件("ぜん")
        handler.db.recordPrefixes(reading: "ぜんぶ", output: "全部")

        XCTAssertEqual(handler.db.fetchHistoryExact(reading: "ぜんぶ"), ["全部"], "フル読みで exact ヒット")
        XCTAssertEqual(handler.db.fetchHistoryExact(reading: "ぜん"),   ["全部"], "N-1 prefix で exact ヒット")
    }

    func testPrefixRecord4Chars() {
        // 4文字のひらがな読みを確定すると prefix も記録される
        // "おはよう"(4文字) → フル + prefix 2件("おは","おはよ")
        handler.db.recordPrefixes(reading: "おはよう", output: "おはよう")

        XCTAssertEqual(handler.db.fetchHistoryExact(reading: "おはよう"), ["おはよう"], "フル読みで exact ヒット")
        XCTAssertEqual(handler.db.fetchHistoryExact(reading: "おはよ"),   ["おはよう"], "N-1 prefix で exact ヒット")
        XCTAssertEqual(handler.db.fetchHistoryExact(reading: "おは"),     ["おはよう"], "N-2 prefix で exact ヒット")
        XCTAssertTrue(handler.db.fetchHistoryExact(reading: "お").isEmpty, "1文字(len<2)は記録しない")
    }

    func testPrefixRecordSkips2Chars() {
        // 2文字はフル読みのみ記録（prefix なし）
        handler.db.recordPrefixes(reading: "とう", output: "東")

        XCTAssertEqual(handler.db.fetchHistoryExact(reading: "とう"), ["東"], "フル読みは記録される")
        XCTAssertTrue(handler.db.fetchHistoryExact(reading: "と").isEmpty, "2文字以下は prefix 記録しない")
    }

    func testPrefixRecordSkipsASCII() {
        // ASCII のみの読みは prefix 記録しない（英字単語モード対策）
        handler.db.recordPrefixes(reading: "github", output: "GitHub")

        XCTAssertEqual(handler.db.fetchHistoryExact(reading: "github"), ["GitHub"], "フル読みは記録される")
        XCTAssertTrue(handler.db.fetchHistoryExact(reading: "githu").isEmpty, "ASCII は prefix 記録しない")
    }

    func testPrefixRecordViaCommit() {
        // 通常確定パスで recordPrefixes が呼ばれ、prefix で候補が出ることを確認
        typeRomaji("toukyou")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")

        // "とうきょ" (prefix) で exact 検索できる
        let result = handler.db.fetchHistoryExact(reading: "とうきょ")
        XCTAssertEqual(result, ["東京"], "確定後、prefix でも履歴ヒットするはず")
    }
}
