import XCTest
@testable import keynaco
import KeynacoCore

final class AzooKeyFooterStatusTests: XCTestCase {

    private func session(
        visible: Bool = true,
        candidates: [String] = [],
        historyEnd: Int = 0,
        fixedEnd: Int = 0,
        azooKeyApiOrder: [String] = [],
        bracketCandidates: [String]? = nil
    ) -> CandidateSession {
        var s = CandidateSession()
        s.candidates = candidates
        s.isVisible = visible
        s.historyEnd = historyEnd
        s.fixedEnd = fixedEnd
        s.azooKeyApiOrder = azooKeyApiOrder
        s.bracketCandidates = bracketCandidates
        return s
    }

    func testHiddenWhenNotVisible() {
        let s = session(visible: false, candidates: ["漢字"], historyEnd: 0)
        XCTAssertNil(AzooKeyFooterStatus.resolve(session: s, isAzooKeyPending: false, isZenzaiRankingActive: false))
    }

    func testHiddenInBracketMode() {
        let s = session(candidates: ["("], bracketCandidates: ["(", ")"])
        XCTAssertNil(AzooKeyFooterStatus.resolve(session: s, isAzooKeyPending: false, isZenzaiRankingActive: false))
    }

    func testFetchingWhenPending() {
        let s = session(candidates: ["かんじ", "カンジ"], historyEnd: 2, fixedEnd: 2)
        XCTAssertEqual(
            AzooKeyFooterStatus.resolve(session: s, isAzooKeyPending: true, isZenzaiRankingActive: false),
            .fetching
        )
    }

    func testFetchingOverridesProvisionalDictionary() {
        let s = session(candidates: ["履歴", "漢字"], historyEnd: 1, fixedEnd: 0)
        XCTAssertEqual(
            AzooKeyFooterStatus.resolve(session: s, isAzooKeyPending: true, isZenzaiRankingActive: true),
            .fetching
        )
    }

    func testDictionaryWhenLoadedWithoutZenzai() {
        let s = session(candidates: ["履歴", "漢字"], historyEnd: 1, fixedEnd: 0)
        XCTAssertEqual(
            AzooKeyFooterStatus.resolve(session: s, isAzooKeyPending: false, isZenzaiRankingActive: false),
            .dictionary
        )
    }

    func testZenzaiWhenRankingActive() {
        let s = session(
            candidates: ["履歴", "漢字"],
            historyEnd: 1,
            fixedEnd: 0,
            azooKeyApiOrder: ["漢字"]
        )
        XCTAssertEqual(
            AzooKeyFooterStatus.resolve(session: s, isAzooKeyPending: false, isZenzaiRankingActive: true),
            .zenzai
        )
    }

    func testNilWhenOnlyHistoryOrKana() {
        let s = session(candidates: ["あい", "アイ"], historyEnd: 2, fixedEnd: 2)
        XCTAssertNil(
            AzooKeyFooterStatus.resolve(session: s, isAzooKeyPending: false, isZenzaiRankingActive: false)
        )
    }

    func testIsAzooKeyPendingBeforeSchedulerStarts() {
        let s = session(candidates: ["かんじ", "カンジ"], historyEnd: 2, fixedEnd: 2)
        XCTAssertTrue(
            AzooKeyFooterStatus.isAzooKeyPending(pendingReading: "かんじ", schedulerPending: false)
        )
        XCTAssertEqual(
            AzooKeyFooterStatus.resolve(
                session: s,
                isAzooKeyPending: AzooKeyFooterStatus.isAzooKeyPending(
                    pendingReading: "かんじ",
                    schedulerPending: false
                ),
                isZenzaiRankingActive: false
            ),
            .fetching
        )
    }

    func testIsAzooKeyPendingWithProvisionalDictionary() {
        let s = session(candidates: ["かん", "漢"], historyEnd: 1, fixedEnd: 0)
        XCTAssertTrue(
            AzooKeyFooterStatus.isAzooKeyPending(pendingReading: "かんじ", schedulerPending: false)
        )
        XCTAssertEqual(
            AzooKeyFooterStatus.resolve(
                session: s,
                isAzooKeyPending: true,
                isZenzaiRankingActive: false
            ),
            .fetching
        )
    }

    func testIsAzooKeyPendingFalseWhenIdle() {
        XCTAssertFalse(
            AzooKeyFooterStatus.isAzooKeyPending(pendingReading: nil, schedulerPending: false)
        )
    }

    func testLabelText() {
        XCTAssertEqual(AzooKeyFooterStatus.fetching.labelText, "辞書取得中…")
        XCTAssertEqual(AzooKeyFooterStatus.dictionary.labelText, "辞書")
        XCTAssertEqual(AzooKeyFooterStatus.zenzai.labelText, "Zenzai")
    }

    func testRawValue() {
        XCTAssertEqual(AzooKeyFooterStatus.fetching.rawValue, "fetching")
        XCTAssertEqual(AzooKeyFooterStatus.dictionary.rawValue, "dictionary")
        XCTAssertEqual(AzooKeyFooterStatus.zenzai.rawValue, "zenzai")
    }
}
