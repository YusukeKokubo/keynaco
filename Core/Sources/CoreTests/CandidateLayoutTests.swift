import XCTest
@testable import KeynacoCore

final class CandidateLayoutTests: XCTestCase {

    private let order = CandidateLayout.defaultSectionOrder

    private func sections(_ pairs: (CandidateSection.Kind, [String])...) -> [CandidateSection] {
        pairs.map { CandidateSection(kind: $0.0, items: $0.1) }
    }

    private func layout(
        _ pairs: (CandidateSection.Kind, [String])...,
        policy: InitialRowPolicy = .afterFixed,
        order customOrder: [CandidateSection.Kind]? = nil
    ) -> CandidateLayout {
        let secs = pairs.map { CandidateSection(kind: $0.0, items: $0.1) }
        return CandidateLayout(sections: secs, sectionOrder: customOrder ?? order, initialRowPolicy: policy)
    }

    // MARK: - 基本

    func testEmptySections() {
        let l = layout()
        XCTAssertEqual(l.candidates, [])
        XCTAssertEqual(l.fixedEnd, 0)
        XCTAssertEqual(l.historyEnd, 0)
        XCTAssertEqual(l.initialRow, 0)
    }

    func testAzooKeyOnly() {
        let l = layout((.azooKeyDict, ["辞書A", "辞書B"]))
        XCTAssertEqual(l.candidates, ["辞書A", "辞書B"])
        XCTAssertEqual(l.fixedEnd, 0)
        XCTAssertEqual(l.historyEnd, 0)
        XCTAssertEqual(l.initialRow, 0)
    }

    // MARK: - 境界計算

    func testFixedHiraganaAlone() {
        let l = layout((.fixedHiragana, ["の"]), (.azooKeyDict, ["辞書A"]), policy: .firstMatching("の"))
        XCTAssertEqual(l.candidates, ["の", "辞書A"])
        XCTAssertEqual(l.fixedEnd, 1)
        XCTAssertEqual(l.historyEnd, 1)
        XCTAssertEqual(l.initialRow, 0)
    }

    func testUserDictAlone() {
        let l = layout((.userDict, ["UD1", "UD2"]), (.azooKeyDict, ["辞書A"]))
        XCTAssertEqual(l.candidates, ["UD1", "UD2", "辞書A"])
        XCTAssertEqual(l.fixedEnd, 2)
        XCTAssertEqual(l.historyEnd, 2)
        XCTAssertEqual(l.initialRow, 2)  // afterFixed → fixedEnd=2
    }

    func testZenzaiTop1Alone() {
        let l = layout((.zenzaiTop1, ["Zen"]), (.azooKeyDict, ["辞書A"]))
        XCTAssertEqual(l.candidates, ["Zen", "辞書A"])
        XCTAssertEqual(l.fixedEnd, 1)
        XCTAssertEqual(l.historyEnd, 1)
        XCTAssertEqual(l.initialRow, 1)
    }

    func testAllBoundaries() {
        // fixedEnd=4, historyEnd=6
        let l = layout(
            (.fixedHiragana, ["の"]),
            (.userDict, ["UD1", "UD2"]),
            (.zenzaiTop1, ["Zen"]),
            (.highHistory, ["H1", "H2"]),
            (.azooKeyDict, ["A1", "A2"])
        )
        XCTAssertEqual(l.candidates, ["の", "UD1", "UD2", "Zen", "H1", "H2", "A1", "A2"])
        XCTAssertEqual(l.fixedEnd, 4)
        XCTAssertEqual(l.historyEnd, 6)
        XCTAssertEqual(l.initialRow, 4)
    }

    func testNumberAndDateTimeBeforeAzooKey() {
        // 現行コードの挿入位置と同じ: number/dateTime → azooKeyDict
        let l = layout(
            (.number, ["１２３"]),
            (.dateTime, ["2026-01-01"]),
            (.azooKeyDict, ["辞書A"])
        )
        XCTAssertEqual(l.candidates, ["１２３", "2026-01-01", "辞書A"])
        XCTAssertEqual(l.historyEnd, 0)  // highHistory なし
    }

    // MARK: - 重複排除

    func testDedupAcrossSections() {
        // fixedHiragana に "重複" → highHistory の "重複" は除外
        let l = layout(
            (.fixedHiragana, ["重複"]),
            (.highHistory, ["重複", "別語"])
        )
        XCTAssertEqual(l.candidates, ["重複", "別語"])
        XCTAssertEqual(l.candidates.filter { $0 == "重複" }.count, 1)
        XCTAssertEqual(l.fixedEnd, 1)
        XCTAssertEqual(l.historyEnd, 2)
    }

    func testDedupWithinSection() {
        let l = layout((.azooKeyDict, ["A", "B", "A", "C", "B"]))
        XCTAssertEqual(l.candidates, ["A", "B", "C"])
    }

    func testDedupFirstOccurrenceWins() {
        // highHistory に "X" → azooKeyDict の "X" は除外
        let l = layout(
            (.highHistory, ["X", "H1"]),
            (.azooKeyDict, ["X", "A1"])
        )
        XCTAssertEqual(l.candidates, ["X", "H1", "A1"])
        XCTAssertEqual(l.candidates.filter { $0 == "X" }.count, 1)
    }

    func testDedupUserDictAlreadyInAzooKey() {
        // userDict が AzooKey より後ろに来るとき（→ fixedEnd に入らない）
        // 実際の buildSections では AzooKey 内にある語は insertedSet で除外済みなので
        // ここでは sectionOrder の順序による dedup を検証する
        let l = layout(
            (.azooKeyDict, ["Acme", "辞書B"]),
            (.userDict, ["Acme"])  // userDict が sectionOrder では azooKeyDict より前なので通常は先に来る
        )
        // sectionOrder では userDict が azooKeyDict より前なので "Acme" は userDict として登録される
        // fixedEnd に "Acme" が入る
        XCTAssertEqual(l.candidates.filter { $0 == "Acme" }.count, 1)
    }

    // MARK: - InitialRowPolicy

    func testPolicyFirstMatchingFound() {
        let l = layout((.fixedHiragana, ["の"]), (.azooKeyDict, ["辞書A"]), policy: .firstMatching("の"))
        XCTAssertEqual(l.initialRow, 0)
    }

    func testPolicyFirstMatchingInHistory() {
        // "の" が highHistory にある（fixedHiragana なし）: firstIndex で見つかる
        let l = layout((.highHistory, ["別語", "の"]), (.azooKeyDict, ["辞書A"]), policy: .firstMatching("の"))
        XCTAssertEqual(l.initialRow, 1)
    }

    func testPolicyFirstMatchingNotFoundFallsToAfterFixed() {
        let l = layout((.fixedHiragana, ["の"]), (.azooKeyDict, ["辞書A"]), policy: .firstMatching("存在しない"))
        XCTAssertEqual(l.initialRow, 1)  // fixedEnd=1
    }

    func testPolicyFirstMatchingNotFoundEmptyFallsToZero() {
        let l = layout(policy: .firstMatching("存在しない"))
        XCTAssertEqual(l.initialRow, 0)  // candidates empty → 0
    }

    func testPolicyAtZero() {
        let l = layout((.highHistory, ["履歴A"]), policy: .atZero)
        XCTAssertEqual(l.initialRow, 0)
    }

    func testPolicyAfterFixed() {
        let l = layout((.fixedHiragana, ["の"]), (.highHistory, ["履歴A"]))
        XCTAssertEqual(l.initialRow, 1)  // fixedEnd=1
    }

    func testPolicyAfterFixedWhenEmptyFallsToZero() {
        let l = layout()
        XCTAssertEqual(l.initialRow, 0)
    }

    func testPolicyAfterFixedWithNoFixedSections() {
        let l = layout((.highHistory, ["H1", "H2"]))
        XCTAssertEqual(l.initialRow, 0)  // fixedEnd=0
    }

    // MARK: - カスタム sectionOrder

    func testCustomSectionOrderWithoutFixedSections() {
        let customOrder: [CandidateSection.Kind] = [.highHistory, .azooKeyDict]
        let l = layout(
            (.highHistory, ["H1"]),
            (.azooKeyDict, ["A1"]),
            order: customOrder
        )
        XCTAssertEqual(l.candidates, ["H1", "A1"])
        XCTAssertEqual(l.fixedEnd, 0)
        XCTAssertEqual(l.historyEnd, 1)
    }

    // MARK: - 不変条件

    func testInvariantFixedEndLeqHistoryEnd() {
        let l = layout((.fixedHiragana, ["の"]), (.highHistory, ["H"]), (.azooKeyDict, ["A"]))
        XCTAssertLessThanOrEqual(l.fixedEnd, l.historyEnd)
    }

    func testInvariantHistoryEndLeqCandidatesCount() {
        let l = layout((.highHistory, ["H"]), (.azooKeyDict, ["A"]))
        XCTAssertLessThanOrEqual(l.historyEnd, l.candidates.count)
    }
}
