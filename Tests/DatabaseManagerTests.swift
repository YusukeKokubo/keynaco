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
}
