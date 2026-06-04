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
    }

    func testBackfillRespectsLimit() {
        let db = DatabaseManager(inMemory: true)
        db.record(input: "せってい", output: "設定")
        db.record(input: "とうきょう", output: "東京")

        let result = AzooKeyPOSBackfill.run(db: db, converter: AzooKeyConverter(), limit: 1)

        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(db.countUnclassifiedHistoryOutputs(), 1)
    }
}
