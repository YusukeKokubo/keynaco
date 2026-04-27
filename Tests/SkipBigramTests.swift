import XCTest
@testable import keynaco

// See: docs/domain/glossary.md#databasemanager

final class SkipBigramTests: InputHandlerTestCase {

    // MARK: - skip_bigram 記録（DatabaseManager）

    func testSkipBigramRecordAndFetch() {
        // 今日 → を → 行く、今日 → が → 走る を確定
        // fetchSkipBigramTop(prev:"今日") が ["行く","走る"] を返す
        handler.db.recordSkipBigram(prev: "今日", input: "いく", output: "行く")
        handler.db.recordSkipBigram(prev: "今日", input: "はしる", output: "走る")

        let results = handler.db.fetchSkipBigramTop(prev: "今日")
        XCTAssertTrue(results.contains("行く"), "行く が上位に含まれる")
        XCTAssertTrue(results.contains("走る"), "走る が上位に含まれる")
    }

    func testSkipBigramNotRecordedWhenPrevIsNotParticle() {
        // 助詞でない語が直前のとき skip-bigram は記録されない
        // 今日 → 行く（直接続けた場合）
        type(chars: "a", base: "a")
        press(keyCode: 36)  // "あ" 確定 (prev = nil)

        typeRomaji("kyo")   // "きょ" 組成
        press(keyCode: 36)  // "きょ" 確定 (prev = "あ"、"あ" は particles に含まれない)

        typeRomaji("iku")
        press(keyCode: 36)  // "いく" 確定 (prev = "きょ"、particles に含まれない)

        // "あ" が prevContent として skip-bigram 記録されないはず
        let results = handler.db.fetchSkipBigramTop(prev: "あ")
        XCTAssertTrue(results.isEmpty, "助詞でない直前語の skip-bigram は記録されない")
    }

    func testSkipBigramRecordedWhenPrevIsParticle() {
        // 今日 → を → 行く のパターン（"を" は助詞）
        // 手動で committedHistory を構築
        handler.db.record(input: "きょう", output: "今日")
        handler.db.record(input: "を", output: "を")

        // commitText の bigram/skip-bigram 記録を直接テストするため
        // committedHistory に "今日"→"を" を積む
        // (InputHandlerTestCase の handler を使って typeRomaji / press でも可だが、
        //  AzooKey の辞書変換結果に依存するためここでは db メソッドを直接テスト)
        handler.db.recordSkipBigram(prev: "今日", input: "いく", output: "行く")
        let results = handler.db.fetchSkipBigramTop(prev: "今日")
        XCTAssertTrue(results.contains("行く"))
    }

    // MARK: - committedHistory の上限

    func testCommittedHistoryCapAt5() {
        // 5件を超えると先頭がドロップされる
        for i in 0..<6 {
            handler.commitText(text: "word\(i)", client: client)
        }
        // committedHistory の末尾は "word5"、上限5件なので "word0" は含まれない
        XCTAssertEqual(handler.lastCommittedOutput, "word5")
        XCTAssertFalse(handler.committedHistory.contains("word0"), "word0 は上限超えでドロップされる")
        XCTAssertEqual(handler.committedHistory.count, 5)
    }

    // MARK: - mostRecentContentWord

    func testMostRecentContentWordSkipsParticle() {
        // committedHistory = ["今日", "を"] のとき mostRecentContentWord = "今日"
        // 直接 handler を通じてテキストをプッシュ
        handler.commitText(text: "今日", client: client)
        handler.commitText(text: "を", client: client)

        let result = handler.mostRecentContentWord()
        XCTAssertEqual(result, "今日", "助詞をスキップして直前の内容語を返す")
    }

    func testMostRecentContentWordNilWhenAllParticles() {
        handler.commitText(text: "を", client: client)
        handler.commitText(text: "に", client: client)

        let result = handler.mostRecentContentWord()
        XCTAssertNil(result, "全て助詞なら nil")
    }

    func testMostRecentContentWordNilWhenHistoryTooShort() {
        handler.commitText(text: "今日", client: client)
        let result = handler.mostRecentContentWord()
        XCTAssertNil(result, "履歴が1件以下なら nil")
    }
}
