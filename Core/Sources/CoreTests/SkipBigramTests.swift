import XCTest
@testable import KeynacoCore

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

    func testMostRecentContentWordReturnsWordWhenHistoryTooShort() {
        handler.commitText(text: "今日", client: client)
        XCTAssertEqual(handler.mostRecentContentWord(), "今日")
    }

    // MARK: - mostRecentContentWords(n:)

    func testMostRecentContentWordsReturnsOneWhenHistoryTooShort() {
        handler.commitText(text: "今日", client: client)
        XCTAssertEqual(handler.mostRecentContentWords(n: 2), ["今日"])
    }

    func testMostRecentContentWordsN1MatchesMostRecentContentWord() {
        handler.commitText(text: "今日", client: client)
        handler.commitText(text: "を", client: client)
        XCTAssertEqual(handler.mostRecentContentWords(n: 1).first, handler.mostRecentContentWord())
    }

    func testMostRecentContentWordsN2SkipsConsecutiveParticles() {
        handler.commitText(text: "今日", client: client)
        handler.commitText(text: "を", client: client)
        handler.commitText(text: "駅", client: client)
        handler.commitText(text: "へ", client: client)
        let words = handler.mostRecentContentWords(n: 2)
        XCTAssertEqual(words, ["駅", "今日"], "助詞をまたいで近い順に2語")
    }

    func testMostRecentContentWordsN2ReturnsOneWhenOnlyOneContentWord() {
        handler.commitText(text: "今日", client: client)
        handler.commitText(text: "を", client: client)
        XCTAssertEqual(handler.mostRecentContentWords(n: 2), ["今日"])
    }

    func testRecordNgramsMultipleSkipBigrams() {
        let mem = DatabaseManager(inMemory: true)
        mem.recordNgrams(
            bigram: (prev: "を", input: "いく", output: "行く"),
            trigram: nil,
            skipBigrams: [
                (prev: "今日", input: "いく", output: "行く"),
                (prev: "昨日", input: "いく", output: "行く"),
            ]
        )
        XCTAssertTrue(mem.fetchSkipBigramTop(prev: "今日").contains("行く"))
        XCTAssertTrue(mem.fetchSkipBigramTop(prev: "昨日").contains("行く"))
    }

    func testPenalizeAllMultipleSkipPrevs() {
        let mem = DatabaseManager(inMemory: true)
        mem.recordSkipBigram(prev: "今日", input: "いく", output: "行く")
        mem.recordSkipBigram(prev: "昨日", input: "いく", output: "行く")
        mem.penalizeAll(
            input: "いく", output: "行く", prev1: nil, prev2: nil,
            skipPrevs: ["今日", "昨日"], fullReading: nil
        )
        XCTAssertFalse(mem.fetchSkipBigramTop(prev: "今日").contains("行く"))
        XCTAssertFalse(mem.fetchSkipBigramTop(prev: "昨日").contains("行く"))
    }

    // MARK: - 文脈リセット（A-1）

    func testSentenceTerminatorClearsHistory() {
        handler.commitText(text: "日本語", client: client)
        handler.commitText(text: "。", client: client)
        XCTAssertTrue(handler.committedHistory.isEmpty, "文末記号確定後に history がリセットされる")
    }

    func testNoBigramAcrossSentenceBoundary() {
        handler.commitText(text: "日本語", client: client)
        handler.commitText(text: "。", client: client)
        handler.commitText(text: "新しい文", client: client)
        let bigramResults = handler.db.fetchBigramTop(prev: "。")
        XCTAssertTrue(bigramResults.isEmpty, "文末記号を prev とする bigram は記録されない")
    }

    func testMostRecentContentWordNilAfterSentenceBreak() {
        handler.commitText(text: "今日", client: client)
        handler.commitText(text: "を", client: client)
        handler.commitText(text: "。", client: client)
        XCTAssertTrue(handler.committedHistory.isEmpty)
        XCTAssertNil(handler.mostRecentContentWord())
    }

    // MARK: - 文末記号後の trigram コンテキストリセット

    func testSentenceTerminatorClearsPrev2Output() {
        // 文末記号確定後は committedHistory が空になり prev2Output / lastCommittedOutput が nil になる
        handler.commitText(text: "昨日", client: client)
        handler.commitText(text: "東京", client: client)
        XCTAssertEqual(handler.lastCommittedOutput, "東京")
        XCTAssertEqual(handler.prev2Output, "昨日")

        handler.commitText(text: "。", client: client)
        XCTAssertTrue(handler.committedHistory.isEmpty, "文末記号確定後に committedHistory がリセットされる")
        XCTAssertNil(handler.lastCommittedOutput, "lastCommittedOutput が nil になるはず")
        XCTAssertNil(handler.prev2Output, "prev2Output が nil になるはず")
    }

    func testSentenceTerminatorPreventsSuccessorAfterNewWord() {
        // 「。」確定後に次の語を確定しても、前の文の bigram コンテキストは使われない
        handler.commitText(text: "東京", client: client)
        handler.commitText(text: "。", client: client)
        handler.commitText(text: "大阪", client: client)
        let bigramFromTokyo = handler.db.fetchBigramTop(prev: "東京")
        XCTAssertTrue(bigramFromTokyo.isEmpty, "文末記号をまたぐ bigram は記録されないはず")
    }
}
