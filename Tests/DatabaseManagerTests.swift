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
        // ひらがな後半の候補（未変換）が辞書後半より先に来る
        // "かえってくる" → "帰ってくる"（未変換 tail）が "帰って来る"（辞書 tail）より先
        db.insertDict(reading: "かえって", candidate: "帰って", priority: 0)
        db.insertDict(reading: "くる", candidate: "来る", priority: 0)

        let result = db.fetchCandidates(prefix: "かえってくる")
        let idxHiragana = result.candidates.firstIndex(of: "帰ってくる")!
        let idxDict = result.candidates.firstIndex(of: "帰って来る")!
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

    func testCompoundPureKanjiHeadWithOkuriganaedTailBlocked() {
        // 純漢字の前半候補 + ひらがなで終わる辞書候補 の組み合わせはスキップされる
        // 例: "堂"(純漢字) + "擦る"(辞書候補、"る"で終わる) → "堂擦る" は不正
        db.insertDict(reading: "どう", candidate: "堂", priority: 0)
        db.insertDict(reading: "する", candidate: "擦る", priority: 0)

        let result = db.fetchCandidates(prefix: "どうする")
        XCTAssertFalse(result.candidates.contains("堂擦る"), "純漢字 + ひらがなで終わる辞書候補は不正")
        XCTAssertFalse(result.candidates.contains("堂する"), "純漢字 + 未変換ひらがなも不正")
    }

    func testCompoundPureKanjiHeadWithPureKanjiTailAllowed() {
        // 純漢字 + 純漢字（ひらがななし）の組み合わせは有効
        // 例: "東京"(純漢字) + "駅"(純漢字) → "東京駅" は有効
        db.insertDict(reading: "とうきょう", candidate: "東京", priority: 0)
        db.insertDict(reading: "えき", candidate: "駅", priority: 0)

        let result = db.fetchCandidates(prefix: "とうきょうえき")
        XCTAssertTrue(result.candidates.contains("東京駅"), "純漢字 + 純漢字は有効")
    }

    func testCompoundNEndingHeadBlocked() {
        // 「ん」で終わる活用形 head + ひらがな tail は不正
        // 例: "かん" → 噛ん（活用形）+ "がえてみて" → "噛んがえてみて" は不正な日本語
        db.insertDict(reading: "かん", candidate: "噛ん", priority: 0)
        db.insertDict(reading: "がえてみて", candidate: "替えてみて", priority: 0)

        let result = db.fetchCandidates(prefix: "かんがえてみて")
        XCTAssertFalse(result.candidates.contains("噛んがえてみて"), "「ん」終わり + ひらがな tail は不正")
        XCTAssertFalse(result.candidates.contains("噛ん替えてみて"), "「ん」終わり head + 辞書 tail も不正")
    }

    func testCompoundKangaeteGeneratesCorrectCompound() {
        // "かんがえてみて" → "考えてみて" / "考えて見て" が生成される
        db.insertDict(reading: "かんがえて", candidate: "考えて", priority: 0)
        db.insertDict(reading: "みて", candidate: "見て", priority: 0)

        let result = db.fetchCandidates(prefix: "かんがえてみて")
        XCTAssertTrue(result.candidates.contains("考えてみて"), "「考えてみて」が候補に含まれるはず")
        XCTAssertTrue(result.candidates.contains("考えて見て"), "「考えて見て」が候補に含まれるはず")
    }

    func testCompoundPureKatakanaHeadWithHiraganaTailBlocked() {
        // 純カタカナ head + ひらがな tail → 不正（"カンガえてみて" 等）
        db.insertDict(reading: "かんが", candidate: "カンガ", priority: 0)

        let result = db.fetchCandidates(prefix: "かんがえてみて")
        XCTAssertFalse(result.candidates.contains { $0.hasPrefix("カンガ") && $0.contains("え") },
                       "純カタカナ head + ひらがな tail は不正")
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

    func testSegmentizeKangaeteMinagara() {
        // 「かんがえてみて」は「かんがえて」+「みて」に分割されるべき
        // >=修正前: スコア同点で「かん」+「がえ」+...になるケース
        db.insertDict(reading: "かんがえ",  candidate: "考え",  priority: 0)
        db.insertDict(reading: "かんがえて", candidate: "考えて", priority: 0)
        db.insertDict(reading: "みて",      candidate: "見て",   priority: 0)

        let segments = db.segmentize("かんがえてみて")
        XCTAssertEqual(segments.map { $0.reading }, ["かんがえて", "みて"],
                       "長いマッチ「かんがえて」が短いマッチより優先される")
    }

    func testSegmentizeLongerMatchWinsOnTie() {
        // スコア同点のとき長いセグメントが勝つ（>=修正の確認）
        // "かんがえ"(4文字)と"かん"(2)+"がえ"(2)がスコア4で同点
        db.insertDict(reading: "かん",    candidate: "勘",  priority: 0)
        db.insertDict(reading: "がえ",    candidate: "替え", priority: 0)
        db.insertDict(reading: "かんがえ", candidate: "考え", priority: 0)

        let segments = db.segmentize("かんがえ")
        XCTAssertEqual(segments.map { $0.reading }, ["かんがえ"],
                       "同スコアなら長い1セグメントが優先される")
    }

    // MARK: - DictionaryImporter: mozc 辞書

    func testMozcBasicNoun() {
        let dictDB = DatabaseManager(inMemoryWithDictionary: true)
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "とうきょう").candidates.contains("東京"))
    }

    func testMozcIchidanVerb() {
        let dictDB = DatabaseManager(inMemoryWithDictionary: true)
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "かんじる").candidates.contains("感じる"))
    }

    func testMozcZRowVerbs() {
        let dictDB = DatabaseManager(inMemoryWithDictionary: true)
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "ろんじる").candidates.contains("論じる"))
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "おうじる").candidates.contains("応じる"))
    }

    func testMozcGodanVerb() {
        let dictDB = DatabaseManager(inMemoryWithDictionary: true)
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "かえる").candidates.contains("帰る"))
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "かいた").candidates.contains("書いた"))
    }

    func testMozcCostOrdering() {
        // ORDER BY priority ASC = 低コスト（高頻度）が先頭
        let dictDB = DatabaseManager(inMemoryWithDictionary: true)
        let result = dictDB.fetchCandidates(prefix: "かいぎ")
        let idxKaigi  = result.candidates.firstIndex(of: "会議")
        let idxKaigi2 = result.candidates.firstIndex(of: "懐疑")
        XCTAssertNotNil(idxKaigi)
        XCTAssertNotNil(idxKaigi2)
        XCTAssertLessThan(idxKaigi!, idxKaigi2!, "会議（高頻度）が懐疑より先")
    }

    // MARK: - 回帰テスト（SKK 現行との比較）

    func testRegressionKanjiru() {
        let dictDB = DatabaseManager(inMemoryWithDictionary: true)
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "かんじる").candidates.contains("感じる"))
    }

    func testRegressionKanjite() {
        let dictDB = DatabaseManager(inMemoryWithDictionary: true)
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "かんじて").candidates.contains("感じて"))
    }

    func testRegressionKanjita() {
        let dictDB = DatabaseManager(inMemoryWithDictionary: true)
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "かんじた").candidates.contains("感じた"))
    }

    // MARK: - Compound: 有効なケースが保持されること

    func testCompoundVerbTeFormWithVerbTaFormAllowed() {
        // 動詞て形 + 動詞た形 の組み合わせは有効
        // 例: "かいてきた" → "書いて来た" は有効
        db.insertDict(reading: "かいて", candidate: "書いて", priority: 0)
        db.insertDict(reading: "きた", candidate: "来た", priority: 0)

        let result = db.fetchCandidates(prefix: "かいてきた")
        XCTAssertTrue(result.candidates.contains("書いて来た"), "動詞て形 + 動詞た形は有効")
    }

    func testCompoundPureKanjiHeadWithMidHiraganaTailBlocked() {
        // 純漢字 head + 内部にひらがなを含む辞書候補（末尾は漢字）もフィルタする
        // 例: "そういうこと" → "層言う事"（層=純漢字, 言う事=末尾は「事」で漢字）
        db.insertDict(reading: "そう", candidate: "層", priority: 0)
        db.insertDict(reading: "いうこと", candidate: "言う事", priority: 0)

        let result = db.fetchCandidates(prefix: "そういうこと")
        XCTAssertFalse(result.candidates.contains("層言う事"),
                       "純漢字 + 内部にひらがなを含む候補は不正")
    }

    func testCompoundOkuriganaHeadWithPureKanjiTailBlocked() {
        // okurigana付き head（末尾がひらがな）+ 純漢字 tail はフィルタする
        // 例: "よさかいぎ" → "良さ会議"（良さ=末尾「さ」がひらがな, 会議=純漢字）
        db.insertDict(reading: "よさ", candidate: "良さ", priority: 0)
        db.insertDict(reading: "かいぎ", candidate: "会議", priority: 0)

        let result = db.fetchCandidates(prefix: "よさかいぎ")
        XCTAssertFalse(result.candidates.contains("良さ会議"),
                       "okurigana付き前半 + 純漢字後半は不正")
    }
}
