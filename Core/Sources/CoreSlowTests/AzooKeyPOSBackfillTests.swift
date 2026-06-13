import XCTest
@testable import KeynacoCore

final class AzooKeyPOSBackfillTests: XCTestCase {
    func testBackfillClassifiesSeededHistory() {
        let db = DatabaseManager(inMemory: true)
        db.record(input: "せってい", output: "設定")
        db.record(input: "とうきょう", output: "東京")

        let result = AzooKeyPOSBackfill.run(db: db, converter: AzooKeyConverter())

        XCTAssertEqual(result.total, 2)
        XCTAssertGreaterThanOrEqual(result.classified, 1)
        let entries = db.fetchAllHistory()
        let settings = entries.first { $0.output == "設定" }
        XCTAssertEqual(settings?.pos, "noun")
        XCTAssertEqual(settings?.lcid, 1283)
    }

    func testBackfillRespectsLimit() {
        let db = DatabaseManager(inMemory: true)
        db.record(input: "せってい", output: "設定")
        db.record(input: "とうきょう", output: "東京")

        let result = AzooKeyPOSBackfill.run(db: db, converter: AzooKeyConverter(), limit: 1)

        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(db.countUnclassifiedHistoryOutputs(), 1)
    }

    func testBackfillReclassifiesStaleOther() {
        let db = DatabaseManager(inMemory: true)
        db.record(input: "しらべる", output: "調べる")
        db.updatePOSClassification(output: "調べる", pos: "other", lcid: nil)

        let result = AzooKeyPOSBackfill.run(db: db, converter: AzooKeyConverter())

        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.classified, 1)
        let entry = db.fetchAllHistory().first { $0.output == "調べる" }
        XCTAssertEqual(entry?.pos, "verb")
        XCTAssertEqual(entry?.lcid, 619)
    }
}
