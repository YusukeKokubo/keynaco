import XCTest
@testable import KeynacoCore

final class FetchLoggerTests: XCTestCase {
    private func temporaryLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fetch-log-\(UUID().uuidString).jsonl")
    }

    func testAppendDefaultsWastedFalse() throws {
        let fileURL = temporaryLogURL()
        let logger = FetchLogger(outputURL: fileURL)
        logger.appVersion = "1.0.0+1"
        logger.append(
            reading: "てすと",
            leftContext: nil,
            fetchMs: 42,
            lockWaitMs: 0,
            rich: true,
            zenzaiEnabled: true
        )
        logger.flushForced()

        let line = try String(contentsOf: fileURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .last!
        let dict = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual(dict["wasted"] as? Bool, false)
        XCTAssertEqual(dict["reading"] as? String, "てすと")
    }

    func testMarkLastFetchWastedUpdatesBufferedRow() throws {
        let fileURL = temporaryLogURL()
        let logger = FetchLogger(outputURL: fileURL)
        logger.append(
            reading: "あい",
            leftContext: nil,
            fetchMs: 10,
            lockWaitMs: 0,
            rich: true,
            zenzaiEnabled: true
        )
        logger.append(
            reading: "あいう",
            leftContext: nil,
            fetchMs: 20,
            lockWaitMs: 0,
            rich: true,
            zenzaiEnabled: true
        )
        logger.markLastFetchWasted(matchingReading: "あい")

        logger.flushForced()
        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .suffix(2)
        let first = try JSONSerialization.jsonObject(with: Data(lines.first!.utf8)) as! [String: Any]
        let second = try JSONSerialization.jsonObject(with: Data(lines.last!.utf8)) as! [String: Any]
        XCTAssertEqual(first["wasted"] as? Bool, true)
        XCTAssertEqual(second["wasted"] as? Bool, false)
    }
}
