import XCTest
@testable import KeynacoCore

// See: docs/domain/states.md#セグメントモード

final class InputHandlerSegmentLLMTests: InputHandlerTestCase {

    func testEnterSegmentModeSetsSegmentLLMTrigger() {
        typeRomaji("watashihagakusei")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else { return }
        let full = handler.state.composedHiragana
        XCTAssertEqual(handler.segmentLLMTrigger, .start(hiragana: full))
    }

    func testEnterSegmentModeWithBoundaryPrefSetsSegmentLLMTrigger() {
        let full = "わたしはがくせい"
        handler.db.saveBoundaryPref(fullReading: full, segments: ["わたし", "はがくせい"])
        typeRomaji("watashihagakusei")
        XCTAssertEqual(handler.state.composedHiragana, full)
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else { return }
        XCTAssertEqual(handler.segmentLLMTrigger, .start(hiragana: full))
    }

    func testApplyLLMSegmentResultInsertsAtHeadAndBumpsSelection() {
        // 実辞書では `inferSegmentBoundaries` が成功しうるため、辞書を空にしたスタブでフォールバック挿入のみを固定する。
        // LLMFallbackForcingMockAzoo は isZenzaiEnabled=false。Zenzai on 時の早期 return を追加してもこの期待値（historyEnd+1 等）は変わらない。
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: LLMFallbackForcingMockAzoo())
        client = MockTextClient()
        typeRomaji("watashihagakusei")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else { return }

        let beforeFirst = handler.state.segmentState!.segments[0].candidates[0]
        let beforeIndex = handler.state.segmentState!.segments[0].selectedIndex
        let beforeHistEnd = handler.state.segmentState!.segments[0].historyEnd
        let llm = "私は学生です"
        handler.applyLLMSegmentResult(text: llm)

        let seg0 = handler.state.segmentState!.segments[0]
        XCTAssertEqual(seg0.candidates.first, llm)
        XCTAssertEqual(handler.state.segmentState!.llmWholeText, llm)
        XCTAssertEqual(seg0.historyEnd, beforeHistEnd + 1)
        XCTAssertEqual(seg0.selectedIndex, beforeIndex + 1)
        XCTAssertEqual(seg0.candidates[beforeIndex + 1], beforeFirst)
    }

    func testApplyLLMSegmentResultSkipsWhenDuplicateReading() {
        typeRomaji("watashihagakusei")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else { return }

        let full = handler.state.segmentState!.segments.map(\.reading).joined()
        handler.applyLLMSegmentResult(text: full)
        XCTAssertNil(handler.state.segmentState!.llmWholeText)
    }

    func testApplyLLMSegmentResultSkipsWhenAlreadyInCandidates() {
        typeRomaji("watashihagakusei")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else { return }

        let existing = handler.state.segmentState!.segments[0].candidates[0]
        handler.applyLLMSegmentResult(text: existing)
        XCTAssertNil(handler.state.segmentState!.llmWholeText)
    }

    func testConfirmLLMWholeTextCommitsOnlyLLMOutput() {
        typeRomaji("watashihagakusei")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else { return }

        let llm = "私は学生です"
        handler.applyLLMSegmentResult(text: llm)
        XCTAssertEqual(handler.state.segmentState!.segments[0].candidates[0], llm)

        let result = press(
            keyCode: KeyCode.enter,
            candidateVisible: true,
            selectedRow: 0,
            selectedText: llm
        )
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertEqual(client.inserted.last, llm)
        guard case .dismiss = result.candidateAction else {
            XCTFail("Successor なしなら .dismiss を期待: \(result.candidateAction)"); return
        }
    }

    func testStaleLlmWholeTextDoesNotShortCircuitWhenFirstCandidateMismatch() {
        typeRomaji("watashihagakusei")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else { return }

        let llm = "私は学生です"
        handler.applyLLMSegmentResult(text: llm)
        XCTAssertEqual(handler.state.segmentState!.llmWholeText, llm)

        // リサイズ後相当: 先頭が LLM と一致しないのに llmWholeText が残っている状態
        var ss = handler.state.segmentState!
        var seg0 = ss.segments[0]
        seg0.candidates = seg0.candidates.filter { $0 != llm }
        XCTAssertFalse(seg0.candidates.isEmpty)
        let other = seg0.candidates[0]
        seg0.selectedIndex = 0
        ss.segments[0] = seg0
        handler.state.segmentState = ss

        let result = press(
            keyCode: KeyCode.enter,
            candidateVisible: true,
            selectedRow: 0,
            selectedText: other
        )
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertNotEqual(client.inserted.last, llm)
        XCTAssertFalse(client.inserted.isEmpty)
        _ = result
    }

    func testZenzaiOnSkipsFallbackInsertWhenInferFails() {
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: ZenzaiOnEmptySegmentCandidatesMockAzoo())
        client = MockTextClient()
        typeRomaji("watashihagakusei")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else {
            XCTFail("セグメントモードに入るはず"); return
        }
        let beforeFirst = handler.state.segmentState!.segments[0].candidates[0]
        let beforeCount = handler.state.segmentState!.segments[0].candidates.count
        let beforeHist = handler.state.segmentState!.segments[0].historyEnd

        handler.applyLLMSegmentResult(text: "私は学生です")

        XCTAssertNil(handler.state.segmentState!.llmWholeText)
        let seg0 = handler.state.segmentState!.segments[0]
        XCTAssertEqual(seg0.candidates.first, beforeFirst)
        XCTAssertEqual(seg0.candidates.count, beforeCount)
        XCTAssertEqual(seg0.historyEnd, beforeHist)
    }
}

/// `candidatesForSegment` が空で infer が失敗するが Zenzai on のため全文フォールバックを抑止する。
private final class ZenzaiOnEmptySegmentCandidatesMockAzoo: AzooKeyConverting, @unchecked Sendable {
    var isZenzaiEnabled: Bool { true }

    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = (hiragana, leftSideContext, richCandidates)
        return []
    }
    func commit(reading: String, text: String) {}
    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        _ = (reading, leftSideContext)
        return []
    }
    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])] {
        _ = leftSideContext
        guard hiragana == "わたしはがくせい" else { return [] }
        return [
            ("わたし", []),
            ("は", []),
            ("がくせい", [])
        ]
    }
}
