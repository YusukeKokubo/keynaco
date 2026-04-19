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
}
