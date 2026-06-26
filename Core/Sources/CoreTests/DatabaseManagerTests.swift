import XCTest
@testable import KeynacoCore

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
        // 1 回の確定で最長読みのみ記録。LIKE 前方一致で短い読みからもヒットする。
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

    func testRecordPrefixesConsolidatesToLongestReading() {
        db.recordPrefixes(reading: "しゅ", output: "種類")
        db.recordPrefixes(reading: "しゅる", output: "種類")
        db.recordPrefixes(reading: "しゅるい", output: "種類")

        let entries = db.fetchAllHistory().filter { $0.output == "種類" }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.input, "しゅるい")
        XCTAssertEqual(entries.first?.count, 3)
        XCTAssertTrue(db.fetchHistoryScoredMerged(reading: "しゅ").map(\.output).contains("種類"))
    }

    func testRecordPrefixesShortConfirmBumpsLongerExisting() {
        db.recordPrefixes(reading: "しゅるい", output: "種類")
        db.recordPrefixes(reading: "しゅ", output: "種類")

        let entries = db.fetchAllHistory().filter { $0.output == "種類" }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.input, "しゅるい")
        XCTAssertEqual(entries.first?.count, 2)
    }

    func testRecordPrefixesKeepsUnrelatedReadingsForSameOutput() {
        db.recordPrefixes(reading: "とうきょう", output: "東京")
        db.recordPrefixes(reading: "tokyo", output: "東京")

        let inputs = Set(db.fetchAllHistory().filter { $0.output == "東京" }.map(\.input))
        XCTAssertEqual(inputs, ["とうきょう", "tokyo"])
    }

    func testIsReadingPrefixAsciiCaseInsensitive() {
        XCTAssertTrue(DatabaseManager.isReadingPrefix("fs", of: "FS、"))
        XCTAssertFalse(DatabaseManager.isReadingPrefix("FS、", of: "fs"))
    }

    // MARK: - 途中確定（truncation）パターンのガード

    /// reading="ないので" / output="ない" のような output が reading の真の prefix な確定は
    /// autoShow 誤確定 or pending romaji 残しの途中確定であり、recordPrefixesOnQueue の
    /// 統合ルールに巻き込まれて行が肥大化する。記録しないこと。
    func testRecordPrefixesSkipsTruncationCommit() {
        db.recordPrefixes(reading: "ないので", output: "ない")
        let entries = db.fetchAllHistory().filter { $0.output == "ない" }
        XCTAssertTrue(entries.isEmpty, "途中確定パターンは記録しない（行ができない）")
    }

    /// truncation 確定が既存の正当な短い行を吸収してはいけない。
    /// バグ前: (ない, ない, 3) が (ないので, ない) に巻き取られ削除され count=4 に育つ。
    /// 修正後: (ない, ない, 3) はそのまま残り、truncation 確定は無視される。
    func testTruncationCommitDoesNotAbsorbShorterRow() {
        db.record(input: "ない", output: "ない")
        db.record(input: "ない", output: "ない")
        db.record(input: "ない", output: "ない")
        db.recordPrefixes(reading: "ないので", output: "ない")

        let entries = db.fetchAllHistory().filter { $0.output == "ない" }
        XCTAssertEqual(entries.count, 1, "短い行は無傷")
        XCTAssertEqual(entries.first?.input, "ない")
        XCTAssertEqual(entries.first?.count, 3, "count は 3 のまま（truncation 確定は加算しない）")
    }

    /// 既存に truncation row が残っていても、新たな短い reading の正当確定はそこへ吸われない。
    /// バグ前: (ないので, ない, 5) があるとき reading="ない" 確定が `recordPrefixesOnQueue` の
    /// (A) longer 統合に拾われ、(ないので, ない) の count が +1 に育つ。
    /// 修正後: longer 統合の filter で truncation row が除外され、新行 (ない, ない, 1) が独立に作られる。
    func testNormalCommitDoesNotFeedExistingTruncationRow() {
        db.record(input: "ないので", output: "ない")
        db.record(input: "ないので", output: "ない")
        db.record(input: "ないので", output: "ない")
        db.record(input: "ないので", output: "ない")
        db.record(input: "ないので", output: "ない")
        // この時点: (ないので, ない, count=5)（バグ行）が単独

        db.recordPrefixes(reading: "ない", output: "ない")

        let entries = db.fetchAllHistory().filter { $0.output == "ない" }
            .sorted { $0.input < $1.input }
        XCTAssertEqual(entries.count, 2, "バグ行と新行が独立に共存")

        let bad = entries.first(where: { $0.input == "ないので" })
        XCTAssertEqual(bad?.count, 5, "truncation row は count=5 のまま育たない")

        let good = entries.first(where: { $0.input == "ない" })
        XCTAssertEqual(good?.count, 1, "新行は独立に作られる")
    }

    /// pending romaji が残ったまま確定された行（reading 末尾にラテン文字残り）も
    /// truncation として扱う。例: reading="やるしかないのd" / output="やるしかない"。
    func testRecordPrefixesSkipsPendingRomajiResidue() {
        db.recordPrefixes(reading: "やるしかないのd", output: "やるしかない")
        let entries = db.fetchAllHistory().filter { $0.output == "やるしかない" }
        XCTAssertTrue(entries.isEmpty, "pending romaji 残しの途中確定も記録しない")
    }

    /// 漢字変換などの「output が reading の prefix にならない」通常確定は影響を受けない。
    func testRecordPrefixesNormalKanjiConfirmStillRecorded() {
        db.recordPrefixes(reading: "とうきょう", output: "東京")
        let entries = db.fetchAllHistory().filter { $0.output == "東京" }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.input, "とうきょう")
    }

    /// reading と output が等しい hiragana 確定（passthrough）は既存ロジックで弾かれる。
    /// truncation ガードは strict prefix（reading が長い）のみが対象。
    func testIsTruncationCommitEdgeCases() {
        // strict prefix（reading が長い）→ true
        XCTAssertTrue(DatabaseManager.isTruncationCommit(reading: "ないので", output: "ない"))
        XCTAssertTrue(DatabaseManager.isTruncationCommit(reading: "ありがとうございます", output: "ありがとう"))
        XCTAssertTrue(DatabaseManager.isTruncationCommit(reading: "やるしかないのd", output: "やるしかない"))
        // 同一 → false
        XCTAssertFalse(DatabaseManager.isTruncationCommit(reading: "ない", output: "ない"))
        // prefix 関係なし（漢字）→ false
        XCTAssertFalse(DatabaseManager.isTruncationCommit(reading: "とうきょう", output: "東京"))
        XCTAssertFalse(DatabaseManager.isTruncationCommit(reading: "しゅ", output: "種類"))
        // output が長い → false
        XCTAssertFalse(DatabaseManager.isTruncationCommit(reading: "とう", output: "東京"))
    }

    func testPenalizeResolvesCanonicalLongerReading() {
        db.recordPrefixes(reading: "しゅるい", output: "種類")
        db.recordPrefixes(reading: "しゅ", output: "種類")
        XCTAssertEqual(
            db.fetchAllHistory().first(where: { $0.output == "種類" })?.count, 2
        )

        db.penalizeAll(input: "しゅ", output: "種類", fullReading: nil)
        XCTAssertEqual(
            db.fetchAllHistory().first(where: { $0.output == "種類" })?.count, 1,
            "短い読みで確定しても最長読みの行をペナルティする"
        )
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

    func testRecencyShortBonusBeatsOlderHighCount() {
        // PLAN260621b（2 段 decay）の意図的な逆転テスト:
        // 1 日以内のごく少ない count（short bonus が乗る）は、
        // 30 日前の高頻度 count（long のみ）に勝つ。
        // 旧設計では count=10/30日前 > count=3/直近 だったが、今は逆。
        // 「直近の好み変更を強く反映」が新仕様。
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
        XCTAssertLessThan(idxNew, idxOld, "直近 count=3 + short bonus が 30 日前 count=10 を上回る")
    }

    func testHistoryEntryScoreTwoStageDecay() {
        // PLAN260621b: HistoryEntry.score の 2 段 decay 数値検証。
        // 直近 0 秒: ~3.0 / 1日前: ~2.0 / 7日前: ~1.06 / 30日前: ~0.56
        let now: Int64 = 1_700_000_000
        func entry(ageDays: Double) -> DatabaseManager.HistoryEntry {
            DatabaseManager.HistoryEntry(
                input: "x", output: "y", count: 1, pos: nil, lcid: nil,
                usedAt: now - Int64(ageDays * 86400)
            )
        }
        XCTAssertEqual(entry(ageDays: 0).score(now: now), 3.0, accuracy: 0.01)
        XCTAssertEqual(entry(ageDays: 1).score(now: now), 1.97, accuracy: 0.05)
        XCTAssertEqual(entry(ageDays: 7).score(now: now), 1.06, accuracy: 0.05)
        XCTAssertEqual(entry(ageDays: 30).score(now: now), 0.56, accuracy: 0.05)
    }

    func testRecencyShortBonusFadesAfter1Day() {
        // PLAN260621b: short tau = 1 日。1 日経過で bonus は半分。
        // 直近確定（age < 1h）と 24h 前確定で、ランキングが逆転する境界を確認。
        let base: Int64 = 1_700_000_000
        let oneHour: Int64 = 3600
        let oneDay: Int64 = 86400
        db.clock = { base }
        db.record(input: "あ", output: "古い直近")  // 24h 後に「古い」になる予定
        db.clock = { base + oneDay - oneHour }  // 23h 後に新規記録
        db.record(input: "あ", output: "より直近")
        db.clock = { base + oneDay }
        let results = db.fetchHistoryExact(reading: "あ")
        let idxRecent = results.firstIndex(of: "より直近")!
        let idxOlder = results.firstIndex(of: "古い直近")!
        XCTAssertLessThan(idxRecent, idxOlder, "1 日以内では直近側が上位（short bonus が支配）")
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
        // performGC は recency スコア < 0.1 を削除（count=1 だと約 9 ヶ月超相当）
        db.clock = { base + 280 * 86400 }
        db.performGCIfNeeded()
        XCTAssertTrue(db.fetchHistoryExact(reading: "あ").isEmpty, "count=1 かつ低スコアは GC で削除")
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

    // MARK: - スキーママイグレーション

    func testInMemoryInitAppliesLatestSchemaVersion() {
        XCTAssertEqual(db.schemaUserVersion, DatabaseManager.schemaVersionLatest)
    }

    func testMigrationsAreIdempotentOnReopen() {
        let path = NSTemporaryDirectory() + "keynaco-migration-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        FileManager.default.createFile(atPath: path, contents: Data())
        let first = DatabaseManager(snapshotPath: path)
        XCTAssertEqual(first.schemaUserVersion, DatabaseManager.schemaVersionLatest)
        let second = DatabaseManager(snapshotPath: path)
        XCTAssertEqual(second.schemaUserVersion, DatabaseManager.schemaVersionLatest)
        second.record(input: "てすと", output: "テスト")
        XCTAssertTrue(second.fetchHistoryExact(reading: "てすと").contains("テスト"))
    }

    // MARK: - penalizeAll（訂正シグナル）

    func testPenalizeAllDeletesHistoryWhenCountReachesZero() {
        db.record(input: "あ", output: "阿")
        db.penalizeAll(input: "あ", output: "阿", fullReading: nil)
        XCTAssertTrue(db.fetchHistoryExact(reading: "あ").isEmpty)
    }
}
