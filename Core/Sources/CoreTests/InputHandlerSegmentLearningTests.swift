import XCTest
@testable import KeynacoCore

/// `doConfirmSelection` で確定語をセグメント分割し、output != reading のセグメントだけを
/// `recordPrefixes` で学習することを検証する。
final class InputHandlerSegmentLearningTests: InputHandlerTestCase {

    private var mock: SegmentLearningMockAzooKey!

    override func setUp() {
        super.setUp()
        mock = SegmentLearningMockAzooKey()
        setUpWithConverter(mock)
    }

    /// 「プロジェクトを進める」確定時:
    /// - "ぷろじぇくと" → "プロジェクト" は学習する
    /// - "を" → "を" は output == reading のためスキップ
    /// - "すすめる" → "進める" は学習する
    func testSegmentLearningSkipsOutputEqualReading() {
        mock.candidateLines = ["プロジェクトを進める"]
        mock.segmentizeResult = [
            (reading: "ぷろじぇくと", candidates: ["プロジェクト"]),
            (reading: "を", candidates: ["を"]),
            (reading: "すすめる", candidates: ["進める"]),
        ]

        typeRomaji("purojekutowosusumeru")
        _ = press(keyCode: KeyCode.enter, candidateVisible: true, selectedText: "プロジェクトを進める")

        // Task.detached で非同期に書き込まれるため、ポーリングで完了を待つ
        waitUntil(timeout: 2.0) {
            !self.handler.db.fetchHistoryExact(reading: "ぷろじぇくと").isEmpty
                && !self.handler.db.fetchHistoryExact(reading: "すすめる").isEmpty
        }

        XCTAssertTrue(
            handler.db.fetchHistoryExact(reading: "ぷろじぇくと").contains("プロジェクト"),
            "output != reading のセグメントは学習される"
        )
        XCTAssertTrue(
            handler.db.fetchHistoryExact(reading: "すすめる").contains("進める"),
            "漢字混じり末尾のセグメントは学習される"
        )
        XCTAssertTrue(
            handler.db.fetchHistoryExact(reading: "を").isEmpty,
            "output == reading の助詞は学習されない（フィルタの主目的）"
        )
    }

    /// 「して欲しい」確定時:
    /// - "して" → "して" はスキップ
    /// - "ほしい" → "欲しい" は学習する
    func testSegmentLearningKeepsKanjiSuffixOnly() {
        mock.candidateLines = ["して欲しい"]
        mock.segmentizeResult = [
            (reading: "して", candidates: ["して"]),
            (reading: "ほしい", candidates: ["欲しい"]),
        ]

        typeRomaji("shitehoshii")
        _ = press(keyCode: KeyCode.enter, candidateVisible: true, selectedText: "して欲しい")

        waitUntil(timeout: 2.0) {
            !self.handler.db.fetchHistoryExact(reading: "ほしい").isEmpty
        }

        XCTAssertTrue(
            handler.db.fetchHistoryExact(reading: "ほしい").contains("欲しい"),
            "漢字に変換された末尾セグメントは学習される"
        )
        XCTAssertTrue(
            handler.db.fetchHistoryExact(reading: "して").isEmpty,
            "ひらがなのままの先頭セグメントはスキップされる"
        )
    }

    // MARK: - ユーティリティ

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

// MARK: - Mock

private final class SegmentLearningMockAzooKey: AzooKeyConverting, @unchecked Sendable {
    var candidateLines: [String] = []
    var segmentizeResult: [(reading: String, candidates: [String])] = []

    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = (hiragana, leftSideContext, richCandidates)
        return candidateLines
    }

    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        _ = (reading, leftSideContext)
        return []
    }

    func commit(reading: String, text: String) { _ = (reading, text) }

    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])] {
        _ = (hiragana, leftSideContext)
        return segmentizeResult
    }
}
