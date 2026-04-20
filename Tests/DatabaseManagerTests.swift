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
}
