import XCTest
@testable import keynaco

final class DatabaseManagerTests: XCTestCase {

    private var db: DatabaseManager!

    override func setUp() {
        super.setUp()
        db = DatabaseManager(inMemory: true)
    }

    override func tearDown() {
        db = nil
        UserDefaults.standard.removeObject(forKey: "lastGCDate")
        super.tearDown()
    }

    // MARK: - 履歴の記録と取得

    func testRecordAndFetch() {
        db.record(input: "かいぎ", output: "会議")
        let results = db.fetchHistoryExact(reading: "かいぎ")
        XCTAssertTrue(results.contains("会議"))
    }

    func testFetchHistoryExactDoesNotMatchPrefix() {
        db.record(input: "かいぎ", output: "会議")
        db.record(input: "かいしゃ", output: "会社")
        let results = db.fetchHistoryExact(reading: "かい")
        XCTAssertFalse(results.contains("会議"), "前方一致は返さない（完全一致のみ）")
        XCTAssertFalse(results.contains("会社"))
    }

    func testHistoryCountUp() {
        db.record(input: "かいぎ", output: "会議")
        db.record(input: "かいぎ", output: "会議")
        db.record(input: "かいぎ", output: "懐疑")
        let results = db.fetchHistoryExact(reading: "かいぎ")
        // 会議 (count=2) が 懐疑 (count=1) より前
        let idxKaigi  = results.firstIndex(of: "会議")!
        let idxKaigi2 = results.firstIndex(of: "懐疑")!
        XCTAssertLessThan(idxKaigi, idxKaigi2)
    }

    func testDeleteHistory() {
        db.record(input: "かいぎ", output: "会議")
        db.deleteHistory(output: "会議")
        let results = db.fetchHistoryExact(reading: "かいぎ")
        XCTAssertFalse(results.contains("会議"))
    }

    func testFetchHistoryExactIsOrderedByFrequency() {
        db.record(input: "あい", output: "愛")
        db.record(input: "あい", output: "愛")
        db.record(input: "あい", output: "相")
        let results = db.fetchHistoryExact(reading: "あい")
        let idxAi  = results.firstIndex(of: "愛")!
        let idxSou = results.firstIndex(of: "相")!
        XCTAssertLessThan(idxAi, idxSou, "使用頻度の高い候補が先頭")
    }

    // MARK: - fetchHistoryPrefix / recordPrefixes

    func testFetchHistoryPrefixReturnsPartialMatch() {
        db.record(input: "かいぎ", output: "会議")
        let results = db.fetchHistoryPrefix(reading: "か")
        XCTAssertTrue(results.contains("会議"), "前方一致する候補を返す")
    }

    func testFetchHistoryPrefixExcludesExactMatch() {
        db.record(input: "かい", output: "会")
        db.record(input: "かいぎ", output: "会議")
        let exact = db.fetchHistoryPrefix(reading: "かい")
        XCTAssertFalse(exact.contains("会"), "完全一致は除外される")
        XCTAssertTrue(exact.contains("会議"))
    }

    func testFetchHistoryPrefixNoDuplicatesWhenMultiplePrefixRowsExist() {
        // recordPrefixes は "えくすぽーと" → "えく"/"えくす"/"えくすぽ"/"えくすぽー"/"えくすぽーと" を全て記録する。
        // fetchHistoryPrefix("え") はこれら全行が LIKE "え%" にマッチするが、
        // GROUP BY output により "エクスポート" は1件だけ返される。
        db.recordPrefixes(reading: "えくすぽーと", output: "エクスポート")
        let results = db.fetchHistoryPrefix(reading: "え")
        let count = results.filter { $0 == "エクスポート" }.count
        XCTAssertEqual(count, 1, "複数のプレフィックス行があっても重複なく1件")
    }

    func testFetchHistoryPrefixDeduplicatesMultipleOutputs() {
        db.recordPrefixes(reading: "えくすぽーと", output: "エクスポート")
        db.recordPrefixes(reading: "えーす", output: "エース")
        let results = db.fetchHistoryPrefix(reading: "え")
        let exportCount = results.filter { $0 == "エクスポート" }.count
        let aceCount    = results.filter { $0 == "エース" }.count
        XCTAssertEqual(exportCount, 1)
        XCTAssertEqual(aceCount, 1)
    }

    func testRecordPrefixesStoresPrefixReading() {
        db.recordPrefixes(reading: "かいぎ", output: "会議")
        // prefix "か" / "かい" でも前方一致して返るか
        XCTAssertTrue(db.fetchHistoryPrefix(reading: "か").contains("会議"))
        XCTAssertTrue(db.fetchHistoryPrefix(reading: "かい").contains("会議"))
        // フル読みは exact で返る
        XCTAssertTrue(db.fetchHistoryExact(reading: "かいぎ").contains("会議"))
    }

    // MARK: - fetchBigramTop

    func testFetchBigramTopEmptyDBReturnsEmpty() {
        let results = db.fetchBigramTop(prev: "東京")
        XCTAssertTrue(results.isEmpty, "学習ゼロなら空配列を返す")
    }

    func testFetchBigramTopSinglePrevReturnsLimited() {
        db.recordBigram(prev: "東京", input: "で", output: "で")
        db.recordBigram(prev: "東京", input: "に", output: "に")
        db.recordBigram(prev: "東京", input: "から", output: "から")
        let results = db.fetchBigramTop(prev: "東京", limit: 2)
        XCTAssertEqual(results.count, 2, "limit で切られる")
    }

    func testFetchBigramTopAggregatesByOutput() {
        // 同じ output ("が") が 2 つの input で学習されている
        db.recordBigram(prev: "東京", input: "が", output: "が")
        db.recordBigram(prev: "東京", input: "がね", output: "が")
        db.recordBigram(prev: "東京", input: "に", output: "に")
        let results = db.fetchBigramTop(prev: "東京")
        let gaCount = results.filter { $0 == "が" }.count
        XCTAssertEqual(gaCount, 1, "同じ output は 1 件に集約される")
        XCTAssertTrue(results.contains("に"))
    }

    func testFetchBigramTopOrderedByCountDesc() {
        // "で" を 3 回、"に" を 1 回学習
        db.recordBigram(prev: "東京", input: "で", output: "で")
        db.recordBigram(prev: "東京", input: "で", output: "で")
        db.recordBigram(prev: "東京", input: "で", output: "で")
        db.recordBigram(prev: "東京", input: "に", output: "に")
        let results = db.fetchBigramTop(prev: "東京")
        let idxDe = results.firstIndex(of: "で")!
        let idxNi = results.firstIndex(of: "に")!
        XCTAssertLessThan(idxDe, idxNi, "count が多い output が先頭")
    }

    func testFetchBigramTopIgnoresOtherPrev() {
        db.recordBigram(prev: "東京", input: "で", output: "で")
        db.recordBigram(prev: "京都", input: "に", output: "に")
        let results = db.fetchBigramTop(prev: "東京")
        XCTAssertTrue(results.contains("で"))
        XCTAssertFalse(results.contains("に"), "別の prev のエントリは混ざらない")
    }

    // MARK: - fetchTrigramTop

    func testFetchTrigramTopEmptyDBReturnsEmpty() {
        let results = db.fetchTrigramTop(prev2: "昨日", prev1: "東京")
        XCTAssertTrue(results.isEmpty, "学習ゼロなら空配列を返す")
    }

    func testFetchTrigramTopAggregatesByOutput() {
        // 同じ output ("行った") が 2 つの input で学習されている
        db.recordTrigram(prev2: "昨日", prev1: "東京", input: "い", output: "行った")
        db.recordTrigram(prev2: "昨日", prev1: "東京", input: "いった", output: "行った")
        db.recordTrigram(prev2: "昨日", prev1: "東京", input: "に", output: "に")
        let results = db.fetchTrigramTop(prev2: "昨日", prev1: "東京")
        let ittaCount = results.filter { $0 == "行った" }.count
        XCTAssertEqual(ittaCount, 1, "同じ output は 1 件に集約される")
        XCTAssertTrue(results.contains("に"))
    }

    func testFetchTrigramTopOrderedByCountDesc() {
        // "行った" を 3 回、"住んだ" を 1 回学習
        db.recordTrigram(prev2: "昨日", prev1: "東京", input: "い", output: "行った")
        db.recordTrigram(prev2: "昨日", prev1: "東京", input: "い", output: "行った")
        db.recordTrigram(prev2: "昨日", prev1: "東京", input: "い", output: "行った")
        db.recordTrigram(prev2: "昨日", prev1: "東京", input: "す", output: "住んだ")
        let results = db.fetchTrigramTop(prev2: "昨日", prev1: "東京")
        let idxItta = results.firstIndex(of: "行った")!
        let idxSunda = results.firstIndex(of: "住んだ")!
        XCTAssertLessThan(idxItta, idxSunda, "count が多い output が先頭")
    }

    func testFetchTrigramTopIsolatedByPrev2Prev1() {
        db.recordTrigram(prev2: "昨日", prev1: "東京", input: "に", output: "行った")
        db.recordTrigram(prev2: "今日", prev1: "東京", input: "に", output: "戻った")
        db.recordTrigram(prev2: "昨日", prev1: "大阪", input: "に", output: "来た")
        let results = db.fetchTrigramTop(prev2: "昨日", prev1: "東京")
        XCTAssertTrue(results.contains("行った"))
        XCTAssertFalse(results.contains("戻った"), "prev2 が違えば混ざらない")
        XCTAssertFalse(results.contains("来た"), "prev1 が違えば混ざらない")
    }

    func testFetchTrigramByReadingPrefix() {
        db.recordTrigram(prev2: "昨日", prev1: "東京", input: "いった", output: "行った")
        db.recordTrigram(prev2: "昨日", prev1: "東京", input: "うえ", output: "上")
        let results = db.fetchTrigram(prev2: "昨日", prev1: "東京", reading: "い")
        XCTAssertTrue(results.contains("行った"), "前方一致で行った が取れる")
        XCTAssertFalse(results.contains("上"), "前方一致しない候補は除外")
    }

    // MARK: - 時間減衰スコアリング（改善 G）

    func testRecencySameCountRecentWins() {
        // 同 count なら直近の方が上位
        let base: Int64 = 1_700_000_000
        db.clock = { base }
        db.record(input: "あい", output: "愛")
        db.clock = { base + 10 }
        db.record(input: "あい", output: "相")
        // どちらも count=1、"相" の方が直近
        db.clock = { base + 20 }
        let results = db.fetchHistoryExact(reading: "あい")
        XCTAssertEqual(results.first, "相", "同 count なら直近の方が上位")
    }

    func testRecencyHighCountOldBeatsLowCountRecent() {
        // count=10 / 30日前 (score≈5.0) と count=3 / 直近 (score=3.0) → 前者が上位
        let base: Int64 = 1_700_000_000
        let tau = Int64(30 * 86400)
        db.clock = { base }
        for _ in 0..<10 { db.record(input: "あ", output: "高頻度古い") }
        db.clock = { base + tau }  // 30日後に直近を記録
        for _ in 0..<3 { db.record(input: "あ", output: "低頻度新しい") }
        db.clock = { base + tau + 10 }
        let results = db.fetchHistoryExact(reading: "あ")
        let idxOld = results.firstIndex(of: "高頻度古い")!
        let idxNew = results.firstIndex(of: "低頻度新しい")!
        XCTAssertLessThan(idxOld, idxNew, "count=10 / score≈5.0 が count=3 / score=3.0 より上位")
    }

    func testRecencyHighCountVeryOldBeatsLowCountRecent() {
        // count=10 / 60日前 (score≈3.33) と count=4 / 直近 (score=4.0) → 後者が上位
        let base: Int64 = 1_700_000_000
        let tau = Int64(30 * 86400)
        db.clock = { base }
        for _ in 0..<10 { db.record(input: "あ", output: "高頻度古い") }
        db.clock = { base + 2 * tau }  // 60日後
        for _ in 0..<4 { db.record(input: "あ", output: "低頻度新しい") }
        db.clock = { base + 2 * tau + 10 }
        let results = db.fetchHistoryExact(reading: "あ")
        let idxOld = results.firstIndex(of: "高頻度古い")!
        let idxNew = results.firstIndex(of: "低頻度新しい")!
        XCTAssertLessThan(idxNew, idxOld, "count=4 / score=4.0 が count=10 / score≈3.33 より上位")
    }

    // MARK: - GC

    func testGCDeletesOldSingleCountEntries() {
        let base: Int64 = 1_700_000_000
        db.clock = { base }
        db.record(input: "あ", output: "古い")
        db.clock = { base + 181 * 86400 }
        db.performGCIfNeeded()
        XCTAssertTrue(db.fetchHistoryExact(reading: "あ").isEmpty, "count=1 かつ 180日超は削除")
    }

    func testGCKeepsHighCountEntries() {
        let base: Int64 = 1_700_000_000
        db.clock = { base }
        db.record(input: "あ", output: "高頻度")
        db.record(input: "あ", output: "高頻度")  // count=2
        db.clock = { base + 181 * 86400 }
        db.performGCIfNeeded()
        XCTAssertTrue(db.fetchHistoryExact(reading: "あ").contains("高頻度"), "count=2 は残る")
    }

    func testGCKeepsRecentSingleCountEntries() {
        let base: Int64 = 1_700_000_000
        db.clock = { base }
        db.record(input: "あ", output: "新しい")  // count=1 だが直近
        db.clock = { base + 90 * 86400 }
        db.performGCIfNeeded()
        XCTAssertTrue(db.fetchHistoryExact(reading: "あ").contains("新しい"), "count=1 でも 90日前は残る")
    }

    func testGCSkipsIfRunRecently() {
        let base: Int64 = 1_700_000_000
        db.clock = { base }
        db.record(input: "あ", output: "古い")
        // 3日前に GC 済みとしてマーク
        UserDefaults.standard.set(base - 3 * 86400, forKey: "lastGCDate")
        db.clock = { base }
        db.performGCIfNeeded()
        XCTAssertTrue(db.fetchHistoryExact(reading: "あ").contains("古い"), "7日以内は GC を実行しない")
    }

    // MARK: - プリセット bi-gram（is_preset）

    func testFetchBigramTopCountIncludesStalePresetRows() {
        let base: Int64 = 1_700_000_000
        let stale = base - 100 * 86400
        db.clock = { stale }
        db.testInsertBigram(
            prev: "東京", input: "へ", output: "行く", count: 5, usedAt: stale, isPreset: true
        )
        db.clock = { base }
        XCTAssertEqual(db.fetchBigramTopCount(prev: "東京"), 5, "90日超のプリセットも閾値に乗る")
    }

    func testReplaceBigramKeepsPresetRows() {
        let t = db.clock()
        db.testInsertBigram(prev: "保持", input: "あ", output: "ア", count: 5, usedAt: t, isPreset: true)
        db.testInsertBigram(prev: "削除対象", input: "い", output: "イ", count: 2, usedAt: t, isPreset: false)
        db.replaceBigram([
            DatabaseManager.BigramEntry(prev: "新規", input: "う", output: "ウ", count: 3),
        ])
        XCTAssertFalse(db.fetchBigram(prev: "保持", reading: "あ").isEmpty, "プリセット行は残る")
        XCTAssertTrue(db.fetchBigram(prev: "削除対象", reading: "い").isEmpty, "非プリセットはインポートで消える")
        XCTAssertFalse(db.fetchBigram(prev: "新規", reading: "う").isEmpty, "インポート行が入る")
    }

    func testGCDoesNotDeleteStalePresetBigram() {
        UserDefaults.standard.removeObject(forKey: "lastGCDate")
        let base: Int64 = 1_700_000_000
        db.clock = { base }
        db.testInsertBigram(prev: "P", input: "x", output: "X", count: 1, usedAt: base, isPreset: true)
        db.clock = { base + 181 * 86400 }
        db.performGCIfNeeded()
        XCTAssertFalse(db.fetchBigram(prev: "P", reading: "x").isEmpty, "プリセットは GC 対象外")
    }

    func testGCDeletesStaleNonPresetBigram() {
        UserDefaults.standard.removeObject(forKey: "lastGCDate")
        let base: Int64 = 1_700_000_000
        db.clock = { base }
        db.testInsertBigram(prev: "U", input: "y", output: "Y", count: 1, usedAt: base, isPreset: false)
        db.clock = { base + 181 * 86400 }
        db.performGCIfNeeded()
        XCTAssertTrue(db.fetchBigram(prev: "U", reading: "y").isEmpty, "非プリセットの count=1 古い行は削除")
    }

    // MARK: - ユーザー辞書

    func testUserDictAddAndFetch() {
        XCTAssertTrue(db.addUserDict(input: "けいなこ", output: "keynaco"))
        let results = db.fetchUserDict(reading: "けいなこ")
        XCTAssertEqual(results, ["keynaco"])
    }

    func testUserDictDuplicateReturnsFalse() {
        db.addUserDict(input: "けいなこ", output: "keynaco")
        XCTAssertFalse(db.addUserDict(input: "けいなこ", output: "keynaco"))
    }

    func testUserDictExactMatchOnly() {
        db.addUserDict(input: "けいなこ", output: "keynaco")
        XCTAssertTrue(db.fetchUserDict(reading: "けいな").isEmpty, "前方一致は返さない")
    }

    func testUserDictDelete() {
        db.addUserDict(input: "けいなこ", output: "keynaco")
        let all = db.fetchAllUserDict()
        guard let entry = all.first else { XCTFail("エントリが存在するはず"); return }
        db.deleteUserDict(id: entry.id)
        XCTAssertTrue(db.fetchUserDict(reading: "けいなこ").isEmpty)
    }

    func testUserDictFetchAllOrdered() {
        db.addUserDict(input: "あ", output: "A")
        db.addUserDict(input: "い", output: "I")
        let all = db.fetchAllUserDict()
        XCTAssertEqual(all.map(\.output), ["A", "I"], "登録順で返る")
    }

    func testUserDictMultipleEntriesSameReading() {
        db.addUserDict(input: "りーなー", output: "Leaner")
        db.addUserDict(input: "りーなー", output: "リーナー株式会社")
        let results = db.fetchUserDict(reading: "りーなー")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0], "Leaner", "登録順が先")
    }

    func testUserDictPrefixMatch() {
        db.addUserDict(input: "とうきょう", output: "東京")
        let results = db.fetchUserDictPrefix(reading: "とうきょうと")
        XCTAssertEqual(results, ["東京"])
    }

    func testUserDictPrefixExcludesExactMatch() {
        db.addUserDict(input: "とうきょう", output: "東京")
        let results = db.fetchUserDictPrefix(reading: "とうきょう")
        XCTAssertTrue(results.isEmpty, "完全一致は除外する")
    }

    func testUserDictPrefixOrderedByRegistration() {
        db.addUserDict(input: "とうきょう", output: "東京")
        db.addUserDict(input: "とうきょうと", output: "東京都")
        let results = db.fetchUserDictPrefix(reading: "とうきょうとちょう")
        XCTAssertEqual(results, ["東京", "東京都"], "登録順で返る")
    }

    // MARK: - boundary_pref

    /// 入力が保存キーで始まれば、より長い別の文でも同じ境界を再利用する
    func testFetchBoundaryPrefPrefixMatchReusesShorterKey() {
        db.saveBoundaryPref(fullReading: "きょうは", segments: ["きょう", "は"])
        let got = db.fetchBoundaryPref(fullReading: "きょうはさむい")
        XCTAssertEqual(got, ["きょう", "は"])
    }

    /// 複数キーが前方一致するときは full_reading が最長の行を返す
    func testFetchBoundaryPrefPrefersLongestMatchingKey() {
        db.saveBoundaryPref(fullReading: "きょうは", segments: ["短い", "前半"])
        db.saveBoundaryPref(fullReading: "きょうはよいてんきです", segments: ["きょう", "はよいてんき", "です"])
        let got = db.fetchBoundaryPref(fullReading: "きょうはよいてんきです")
        XCTAssertEqual(got, ["きょう", "はよいてんき", "です"])
    }

    /// 入力が保存キーより短いときはヒットしない（入力がキーで始まる必要がある）
    func testFetchBoundaryPrefNoHitWhenInputDoesNotStartWithKey() {
        db.saveBoundaryPref(fullReading: "きょうは", segments: ["きょう", "は"])
        XCTAssertNil(db.fetchBoundaryPref(fullReading: "きょう"))
    }

    /// full_reading が 4 文字未満のときは保存しない・取得もしない
    func testSaveBoundaryPrefIgnoresShortReading() {
        db.saveBoundaryPref(fullReading: "きょ", segments: ["きょ"])
        XCTAssertNil(db.fetchBoundaryPref(fullReading: "きょ"), "4文字未満は保存されない")
    }
}
