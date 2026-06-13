import XCTest
@testable import KeynacoCore

final class CandidateRowSectionTests: XCTestCase {

    func testSectionFixedHistoryDictionary() {
        XCTAssertEqual(
            CandidateRowMetadata.section(row: 0, fixedEnd: 2, historyEnd: 4),
            .fixed
        )
        XCTAssertEqual(
            CandidateRowMetadata.section(row: 2, fixedEnd: 2, historyEnd: 4),
            .history
        )
        XCTAssertEqual(
            CandidateRowMetadata.section(row: 4, fixedEnd: 2, historyEnd: 4),
            .dictionary
        )
    }

    func testHistoryRowBoundaries() {
        XCTAssertFalse(CandidateRowMetadata.isHistoryRow(row: 0, fixedEnd: 1, historyEnd: 3))
        XCTAssertTrue(CandidateRowMetadata.isHistoryRow(row: 1, fixedEnd: 1, historyEnd: 3))
        XCTAssertTrue(CandidateRowMetadata.isHistoryRow(row: 2, fixedEnd: 1, historyEnd: 3))
        XCTAssertFalse(CandidateRowMetadata.isHistoryRow(row: 3, fixedEnd: 1, historyEnd: 3))
    }

    func testShowsDeleteButtonMatchesHistoryRows() {
        XCTAssertFalse(CandidateRowMetadata.showsDeleteButton(row: 0, fixedEnd: 1, historyEnd: 2))
        XCTAssertTrue(CandidateRowMetadata.showsDeleteButton(row: 1, fixedEnd: 1, historyEnd: 2))
    }

    func testSectionDividerAtHistoryEndMinusOne() {
        XCTAssertTrue(CandidateRowMetadata.showsSectionDivider(row: 2, historyEnd: 3, candidateCount: 5))
        XCTAssertFalse(CandidateRowMetadata.showsSectionDivider(row: 2, historyEnd: 3, candidateCount: 3))
        XCTAssertFalse(CandidateRowMetadata.showsSectionDivider(row: 1, historyEnd: 3, candidateCount: 5))
    }
}
