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

    // MARK: - applyLLMBoundaries + Zenzai on: reorderSegmentCandidatesZenzaiBeforeLLM

    func testZenzaiReorderZenTopBeforeTokenBothInDict() {
        // zenTop（"新規"）と LLM token（"信機"）がともに辞書セクション（>= historyEnd）にあるとき、
        // zenTop が先頭、token が2番目、selectedIndex=0、historyEnd が正しく更新されることを確認。
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: ZenzaiKyouHashinnkiMock())
        client = MockTextClient()
        typeRomaji("kyouhashinki")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else { XCTFail("セグメントモードに入るはず"); return }

        handler.applyLLMSegmentResult(text: "今日は信機")
        guard let ss = handler.state.segmentState else { XCTFail("LLM 適用後 segmentState があるはず"); return }
        XCTAssertTrue(ss.isLlmBoundaryInferred)

        let seg2 = ss.segments[2]
        XCTAssertEqual(seg2.candidates.first, "新規", "zenTop が LLM token より先頭")
        XCTAssertEqual(seg2.candidates[safe: 1], "信機", "LLM token が2番目")
        XCTAssertEqual(seg2.selectedIndex, 0)
        // fixed=2、zenTop と token の両方が dict から先頭へ移動 → historyEnd = 2 + 2 = 4
        XCTAssertEqual(seg2.historyEnd, 4)
    }

    func testZenzaiReorderHistoryEndWhenTokenNew() {
        // zenTop（"新規"）は辞書セクションにあり、LLM token（"お知らせ"）が候補列に存在しない（新規）ケース。
        // historyEnd が +2 になることを固定する（旧実装は +1 でバグがあった）。
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: ZenzaiKyouHashinnkiMock())
        client = MockTextClient()
        typeRomaji("kyouhashinki")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else { XCTFail("セグメントモードに入るはず"); return }

        // "新型" は candidatesForSegment("しんき") に含まれないが kanji なので inferSegmentBoundaries の
        // fallback path（baseline segment reading を消費）で pairs 成立する。
        // applyLLMBoundaries で token が候補列にない → reorder の "zenTop のみ remove + 2行 insert" ケース。
        handler.applyLLMSegmentResult(text: "今日は新型")
        guard let ss = handler.state.segmentState else { XCTFail("LLM 適用後 segmentState があるはず"); return }
        XCTAssertTrue(ss.isLlmBoundaryInferred)

        let seg2 = ss.segments[2]
        XCTAssertEqual(seg2.candidates.first, "新規", "zenTop が新規 LLM token より先頭")
        XCTAssertEqual(seg2.candidates[safe: 1], "新型", "新規 LLM token が2番目")
        XCTAssertEqual(seg2.selectedIndex, 0)
        // fixed=2、zenTop のみ dict から除去 + 2行挿入 → historyEnd = 2 + 2 = 4（旧バグ: 3）
        XCTAssertEqual(seg2.historyEnd, 4)
    }

    func testZenzaiOnLlmShortcutNotFiredAfterReorder() {
        // Zenzai on + applyLLMBoundaries 後は candidates[0] の連結が llmWholeText と一致しないため
        // isLlmWholeTextShortcut が false を返し、Enter は通常の全文節連結確定にフォールスルーする。
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: ZenzaiKyouHashinnkiMock())
        client = MockTextClient()
        typeRomaji("kyouhashinki")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else { XCTFail("セグメントモードに入るはず"); return }

        // LLM token "信機" が seg2 に適用されると zenTop "新規" が先頭になる。
        // candidates[0] 連結 "今日は新規" ≠ llmWholeText "今日は信機" → shortcut false。
        handler.applyLLMSegmentResult(text: "今日は信機")
        guard let ss = handler.state.segmentState else { XCTFail("LLM 適用後 segmentState があるはず"); return }
        XCTAssertFalse(
            handler.isLlmWholeTextShortcut(segmentState: ss, candidateSelectedText: ss.focusedSegment.candidates.first),
            "zenTop が先頭になると LLM 全文一括ショートカットは成立しない"
        )

        _ = press(keyCode: KeyCode.enter, candidateVisible: true, selectedRow: 0, selectedText: ss.segments[0].candidates[0])
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertFalse(client.inserted.contains("今日は信機"), "LLM 全文が1回で確定されることはない")
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

/// Zenzai on + アライメント成功ケース用。"きょうはしんき" の3文節と各読みの辞書候補を返す。
/// candidatesForSegment("しんき") = ["新規", "信機"] で zenTop と LLM token を分離できる。
private final class ZenzaiKyouHashinnkiMock: AzooKeyConverting, @unchecked Sendable {
    var isZenzaiEnabled: Bool { true }

    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = (hiragana, leftSideContext, richCandidates); return []
    }
    func commit(reading: String, text: String) {}

    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        _ = leftSideContext
        switch reading {
        case "きょう": return ["今日"]
        case "は":    return ["は"]
        case "しんき": return ["新規", "信機"]
        default:      return []
        }
    }

    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])] {
        _ = leftSideContext
        guard hiragana == "きょうはしんき" else { return [] }
        return [
            ("きょう", ["今日"]),
            ("は",    ["は"]),
            ("しんき", ["新規", "信機"])
        ]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
