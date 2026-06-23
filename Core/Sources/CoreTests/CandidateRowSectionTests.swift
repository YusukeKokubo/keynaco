import XCTest
@testable import KeynacoCore

final class CandidateRowSectionTests: XCTestCase {

    func testSectionFromSourceMetadata() {
        XCTAssertEqual(CandidateRowMetadata.section(for: .hiraganaBuiltin), .fixed)
        XCTAssertEqual(CandidateRowMetadata.section(for: .historyPrefix), .history)
        XCTAssertEqual(CandidateRowMetadata.section(for: .azooKey(rank: 0)), .dictionary)
    }

    func testLegacyFixedEndContiguousPrefix() {
        let sources: [ScoredCandidate.Source] = [
            .hiraganaBuiltin,
            .historyPrefix,
            .azooKey(rank: 0),
        ]
        XCTAssertEqual(CandidateRowMetadata.legacyFixedEnd(sources: sources), 1)
    }

    func testHistoryDeleteUsesSourceNotContiguousIndex() {
        let sources: [ScoredCandidate.Source] = [
            .historyExact,
            .userDict(isExact: true),
            .historyPrefix,
        ]
        XCTAssertTrue(CandidateRowMetadata.showsDeleteButton(row: 0, sources: sources))
        XCTAssertFalse(CandidateRowMetadata.showsDeleteButton(row: 1, sources: sources))
        XCTAssertTrue(CandidateRowMetadata.showsDeleteButton(row: 2, sources: sources))
    }

    func testSectionDividerOnSourceTransition() {
        let sources: [ScoredCandidate.Source] = [
            .historyPrefix,
            .azooKey(rank: 0),
        ]
        XCTAssertTrue(CandidateRowMetadata.showsSectionDivider(row: 0, sources: sources))
        XCTAssertFalse(CandidateRowMetadata.showsSectionDivider(row: 1, sources: sources))
    }
}
