import XCTest
@testable import ykey

final class DatabaseManagerTests: XCTestCase {

    private var db: DatabaseManager!

    override func setUp() {
        super.setUp()
        db = DatabaseManager(inMemory: true)
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    // MARK: - 履歴

    func testRecordAndFetch() {
        db.record(input: "かいぎ", output: "会議")
        let result = db.fetchCandidates(prefix: "かいぎ")
        XCTAssertTrue(result.candidates.contains("会議"))
        XCTAssertEqual(result.historyCount, 1)
    }

    func testHistoryPrefixMatch() {
        db.record(input: "かいぎ", output: "会議")
        db.record(input: "かいしゃ", output: "会社")
        let result = db.fetchCandidates(prefix: "かい")
        XCTAssertTrue(result.candidates.contains("会議"))
        XCTAssertTrue(result.candidates.contains("会社"))
        XCTAssertEqual(result.historyCount, 2)
    }

    func testHistoryCountUp() {
        db.record(input: "かいぎ", output: "会議")
        db.record(input: "かいぎ", output: "会議")
        db.record(input: "かいぎ", output: "懐疑")
        let result = db.fetchCandidates(prefix: "かいぎ")
        // 会議 (count=2) が 懐疑 (count=1) より前
        let idxKaigi = result.candidates.firstIndex(of: "会議")!
        let idxKaigi2 = result.candidates.firstIndex(of: "懐疑")!
        XCTAssertLessThan(idxKaigi, idxKaigi2)
    }

    func testDeleteHistory() {
        db.record(input: "かいぎ", output: "会議")
        db.deleteHistory(output: "会議")
        let result = db.fetchCandidates(prefix: "かいぎ")
        XCTAssertFalse(result.candidates.contains("会議"))
    }

    // MARK: - 辞書

    func testDictExactMatch() {
        db.insertDict(reading: "かいぎ", candidate: "会議", priority: 0)
        db.insertDict(reading: "かいぎ", candidate: "懐疑", priority: 1)
        let result = db.fetchCandidates(prefix: "かいぎ")
        XCTAssertTrue(result.candidates.contains("会議"))
        XCTAssertTrue(result.candidates.contains("懐疑"))
        XCTAssertEqual(result.historyCount, 0)
    }

    func testDictPriorityOrder() {
        db.insertDict(reading: "かいぎ", candidate: "懐疑", priority: 1)
        db.insertDict(reading: "かいぎ", candidate: "会議", priority: 0)
        let result = db.fetchCandidates(prefix: "かいぎ")
        let idx0 = result.candidates.firstIndex(of: "会議")!
        let idx1 = result.candidates.firstIndex(of: "懐疑")!
        XCTAssertLessThan(idx0, idx1)
    }

    // MARK: - 履歴 + 辞書の統合

    func testHistoryBeforeDict() {
        db.insertDict(reading: "かいぎ", candidate: "会議", priority: 0)
        db.insertDict(reading: "かいぎ", candidate: "懐疑", priority: 1)
        db.record(input: "かいぎ", output: "懐疑")

        let result = db.fetchCandidates(prefix: "かいぎ")
        // 履歴の懐疑が辞書の会議より前に来る
        let idxKaigi = result.candidates.firstIndex(of: "懐疑")!
        let idxDict = result.candidates.firstIndex(of: "会議")!
        XCTAssertLessThan(idxKaigi, idxDict)
        XCTAssertEqual(result.historyCount, 1)
    }

    func testNoDuplicateBetweenHistoryAndDict() {
        db.insertDict(reading: "かいぎ", candidate: "会議", priority: 0)
        db.record(input: "かいぎ", output: "会議")

        let result = db.fetchCandidates(prefix: "かいぎ")
        let count = result.candidates.filter { $0 == "会議" }.count
        XCTAssertEqual(count, 1)
    }

    // MARK: - 分割変換

    func testCompoundConversion() {
        db.insertDict(reading: "かんじ", candidate: "感じ", priority: 0)
        db.insertDict(reading: "かんじ", candidate: "漢字", priority: 1)

        let result = db.fetchCandidates(prefix: "いいかんじ")
        XCTAssertTrue(result.candidates.contains("いい感じ"), "ひらがな前半 + 辞書後半")
        XCTAssertTrue(result.candidates.contains("いい漢字"))
    }

    func testCompoundWithDictHead() {
        db.insertDict(reading: "いい", candidate: "良い", priority: 0)
        db.insertDict(reading: "かんじ", candidate: "感じ", priority: 0)

        let result = db.fetchCandidates(prefix: "いいかんじ")
        XCTAssertTrue(result.candidates.contains("いい感じ"), "ひらがな前半 + 辞書後半")
        XCTAssertTrue(result.candidates.contains("良い感じ"), "辞書前半 + 辞書後半")
    }

    func testCompoundWithHiraganaTail() {
        // "よさそう" → "良さそう"（辞書前半 + ひらがな後半）
        db.insertDict(reading: "よさ", candidate: "良さ", priority: 0)
        db.insertDict(reading: "そう", candidate: "層", priority: 0)

        let result = db.fetchCandidates(prefix: "よさそう")
        XCTAssertTrue(result.candidates.contains("良さそう"), "辞書前半 + ひらがな後半")
    }

    func testCompoundHiraganaTailBeforeDictTail() {
        // ひらがな後半の候補が辞書後半より先に来る
        db.insertDict(reading: "よさ", candidate: "良さ", priority: 0)
        db.insertDict(reading: "そう", candidate: "層", priority: 0)

        let result = db.fetchCandidates(prefix: "よさそう")
        let idxHiragana = result.candidates.firstIndex(of: "良さそう")!
        let idxDict = result.candidates.firstIndex(of: "良さ層")!
        XCTAssertLessThan(idxHiragana, idxDict, "ひらがな後半が辞書後半より先")
    }

    func testCompoundPureKanjiHeadWithHiraganaTailBlocked() {
        // 純漢字の前半候補 + 未変換ひらがな後半 の組み合わせはスキップされる
        // 例: "同"(純漢字) + "いうこと"(未変換) → "同いうこと" は不正な日本語
        db.insertDict(reading: "どう", candidate: "同", priority: 0)
        db.insertDict(reading: "いうこと", candidate: "言う事", priority: 0)

        let result = db.fetchCandidates(prefix: "どういうこと")
        XCTAssertFalse(result.candidates.contains("同いうこと"), "純漢字 + ひらがなは不正なのでスキップ")
        XCTAssertTrue(result.candidates.contains("どう言う事"), "ひらがな前半 + 辞書後半は有効")
    }

    func testCompoundKanjiWithOkuriganaHeadAllowed() {
        // 送り仮名つき漢字（ひらがなを含む）は未変換ひらがな後半と組み合わせてよい
        // 例: "良さ"(ひらがな「さ」を含む) + "そう" → "良さそう" は有効
        db.insertDict(reading: "よさ", candidate: "良さ", priority: 0)
        db.insertDict(reading: "そう", candidate: "層", priority: 0)

        let result = db.fetchCandidates(prefix: "よさそう")
        XCTAssertTrue(result.candidates.contains("良さそう"), "okurigana付き漢字 + ひらがなは有効")
    }

    // MARK: - 動詞活用（okuri-ari 展開）

    func testVerbMasuForm() {
        // okuri-ari 展開で "いき" → "行き" が登録されていれば
        // 分割変換 "いき" + "ます" → "行きます" が得られる
        db.insertDict(reading: "いき", candidate: "行き", priority: 0)

        let result = db.fetchCandidates(prefix: "いきます")
        XCTAssertTrue(result.candidates.contains("行きます"), "いきます → 行きます")
    }

    func testVerbDictForm() {
        // "いく" → "行く" が辞書にある場合（okuri-ari 展開の辞書形）
        db.insertDict(reading: "いく", candidate: "行く", priority: 0)

        let result = db.fetchCandidates(prefix: "いく")
        XCTAssertTrue(result.candidates.contains("行く"), "いく → 行く")
    }

    // MARK: - segmentize

    func testSegmentizeSingleSegment() {
        db.insertDict(reading: "かいぎ", candidate: "会議", priority: 0)
        let segments = db.segmentize("かいぎ")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].reading, "かいぎ")
        XCTAssertFalse(segments[0].candidates.isEmpty)
    }

    func testSegmentizeMultipleSegments() {
        db.insertDict(reading: "わたし", candidate: "私", priority: 0)
        db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)
        // "は" は辞書なし → 1文字セグメント
        let segments = db.segmentize("わたしはがくせい")
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].reading, "わたし")
        XCTAssertEqual(segments[1].reading, "は")
        XCTAssertEqual(segments[2].reading, "がくせい")
        XCTAssertFalse(segments[0].candidates.isEmpty)
        XCTAssertTrue(segments[1].candidates.isEmpty, "助詞「は」は辞書エントリなし")
        XCTAssertFalse(segments[2].candidates.isEmpty)
    }

    func testSegmentizeParticle() {
        // 辞書にない1文字が1セグメントになる
        let segments = db.segmentize("は")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].reading, "は")
        XCTAssertTrue(segments[0].candidates.isEmpty)
    }

    // MARK: - segmentize DP + 履歴スコアリング

    func testSegmentizeDPPrefersMoreDictCoverage() {
        // Greedy が失敗するケース: "はなみずき"
        // 辞書に "はな"(花) と "みずき"(水木) がある（"はなみ" もある）
        // Greedy: ["はなみ", "ず", "き"] / DP: ["はな", "みずき"]
        db.insertDict(reading: "はな",  candidate: "花",  priority: 0)
        db.insertDict(reading: "はなみ", candidate: "花見", priority: 0)
        db.insertDict(reading: "みずき", candidate: "水木", priority: 0)

        let segments = db.segmentize("はなみずき")
        XCTAssertEqual(segments.map { $0.reading }, ["はな", "みずき"],
                       "DP は辞書カバレッジが高い分割を選ぶ")
    }

    func testSegmentizeHistoryBoostsUnknownWord() {
        // 辞書にない "タワー" を履歴に入れると正しく分割される
        db.insertDict(reading: "とうきょう", candidate: "東京", priority: 0)
        db.record(input: "タワー", output: "タワー")

        let segments = db.segmentize("とうきょうタワー")
        XCTAssertEqual(segments.map { $0.reading }, ["とうきょう", "タワー"],
                       "履歴にある未知語が1セグメントとして切り出される")
    }

    func testSegmentizeHistoryBoostsPreferredSplit() {
        // 辞書スコアが同等の候補を履歴スコアで逆転させる
        // "うれしい" は辞書に2文字ずつ分割できる ("うれ" + "しい") が
        // 履歴に "うれしい" があれば1セグメントになる
        db.insertDict(reading: "うれ",   candidate: "憂",   priority: 0)
        db.insertDict(reading: "しい",   candidate: "しい", priority: 0)
        db.insertDict(reading: "うれしい", candidate: "嬉しい", priority: 0)
        db.record(input: "うれしい", output: "嬉しい")
        db.record(input: "うれしい", output: "嬉しい")

        let segments = db.segmentize("うれしい")
        XCTAssertEqual(segments.map { $0.reading }, ["うれしい"],
                       "履歴スコアで4文字1セグメントが勝つ")
    }

    func testSegmentizeNoHistoryFallsBackToDict() {
        // 履歴が空の場合、辞書スコアのみで分割される
        db.insertDict(reading: "わたし",  candidate: "私",  priority: 0)
        db.insertDict(reading: "がくせい", candidate: "学生", priority: 0)

        let segments = db.segmentize("わたしがくせい")
        XCTAssertEqual(segments.map { $0.reading }, ["わたし", "がくせい"],
                       "履歴なしでも辞書スコアで正しく分割される")
    }

    // MARK: - DictionaryImporter: 重複子音エントリの basic expansion 抑制

    func testOkuriAriInvalidFormExcluded() {
        // "しt /知/" の basic expansion で生成される "知た" は無効な日本語形。
        // 同じ (幹=し, 候補=知) に "しr /知/" (ら行五段) があるため "t" 行は抑制される。
        let dictDB = DatabaseManager(inMemoryWithDictionary: true)
        let candidates = dictDB.fetchCandidates(prefix: "した").candidates
        XCTAssertFalse(candidates.contains("知た"), "知た は無効形なので候補に出ないこと")
        XCTAssertFalse(candidates.contains("散た"), "散た は無効形なので候補に出ないこと")
    }

    func testOkuriAriValidRRowFormsPreserved() {
        // "しr /知/" の basic expansion による ら行 活用形は保持される
        let dictDB = DatabaseManager(inMemoryWithDictionary: true)
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "しる").candidates.contains("知る"))
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "しら").candidates.contains("知ら"))
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "しった").candidates.contains("知った"))
    }

    func testOkuriAriTaRowVerbFormsPreserved() {
        // 勝つ (た行五段) は "かt" エントリのみ → basic expansion は抑制されず全形保持
        let dictDB = DatabaseManager(inMemoryWithDictionary: true)
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "かつ").candidates.contains("勝つ"))
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "かち").candidates.contains("勝ち"))
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "かった").candidates.contains("勝った"))
    }
}
