import XCTest
@testable import KeynacoCore

// boundary_pref（B-1 手動境界・B-2 LLM 多文節）。docs/domain/glossary.md DatabaseManager 参照。

final class InputHandlerSegmentBoundaryPrefTests: InputHandlerTestCase {

    // MARK: - B-1 境界学習

    func testBoundaryPrefSavedOnManualAdjust() {
        typeRomaji("kyouha")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss = handler.state.segmentState,
              ss.segments.count >= 2 else { return }
        press(keyCode: 123, modifiers: .shift)
        press(keyCode: 36)
        XCTAssertNotNil(handler.db.fetchBoundaryPref(fullReading: "きょうは"),
                        "手動調整後に boundary_pref が保存されるはず")
    }

    func testBoundaryPrefReproducedOnReenter() {
        typeRomaji("kyouha")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss = handler.state.segmentState,
              ss.segments.count >= 2 else { return }
        press(keyCode: 123, modifiers: .shift)
        guard let adjusted = handler.state.segmentState else { return }
        let adjustedReadings = adjusted.segments.map { $0.reading }
        press(keyCode: 36)

        typeRomaji("kyouha")
        press(keyCode: 49)
        guard handler.state.isSegmentMode, let ss2 = handler.state.segmentState else { return }
        XCTAssertEqual(ss2.segments.map { $0.reading }, adjustedReadings,
                       "再入力時に保存済み境界が再現されるはず")
    }

    func testBoundaryPrefNotSavedWithoutAdjust() {
        typeRomaji("kyouha")
        press(keyCode: 49)
        guard handler.state.isSegmentMode else { return }
        press(keyCode: 36)
        XCTAssertNil(handler.db.fetchBoundaryPref(fullReading: "きょうは"),
                     "手動調整なしの確定では boundary_pref に保存されないはず")
    }

    func testBoundaryPrefFallbackToAzooKey() {
        XCTAssertNil(handler.db.fetchBoundaryPref(fullReading: "みらいのはなし"))
        typeRomaji("mirainohananashi")
        press(keyCode: 49)
        XCTAssertTrue(handler.state.isSegmentMode,
                      "DB にエントリがなくても AzooKey 分割でセグメントモードに入れるはず")
    }

    // MARK: - B-2 LLM 多文節境界 → boundary_pref 自動保存（PLAN260503e）

    func testBoundaryPrefSavedAfterLlmMultiSegmentShortcut() {
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: BoundaryPrefLLMMockKyouHaii())
        client = MockTextClient()
        typeRomaji("kyouhaii")
        XCTAssertEqual(handler.state.composedHiragana, "きょうはいい")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else {
            XCTFail("スタブ segmentize でセグメントモードに入るはず"); return
        }
        handler.applyLLMSegmentResult(text: "今日はイイ")
        guard let ss = handler.state.segmentState else {
            XCTFail("LLM 結果適用後も segmentState があるはず"); return
        }
        XCTAssertTrue(ss.isLlmBoundaryInferred)
        XCTAssertEqual(ss.segments.map(\.reading), ["きょう", "は", "いい"])
        let segI = ss.segments[2]
        XCTAssertEqual(segI.reading, "いい")
        XCTAssertEqual(segI.candidates[0], "いい", "Zenzai on: candidatesForSegment 先頭が LLM トークン「イイ」より前")
        XCTAssertEqual(segI.candidates[1], "イイ")

        _ = press(
            keyCode: KeyCode.enter,
            candidateVisible: true,
            selectedRow: 0,
            selectedText: ss.segments[0].candidates[0]
        )
        XCTAssertEqual(handler.db.fetchBoundaryPref(fullReading: "きょうはいい"), ["きょう", "は", "いい"])
    }

    func testBoundaryPrefSavedAfterLlmMultiSegmentNormalConfirm() {
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: BoundaryPrefLLMMockKyouHaii())
        client = MockTextClient()
        typeRomaji("kyouhaii")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else { return }
        handler.applyLLMSegmentResult(text: "今日はイイ")
        guard handler.state.segmentState != nil else { return }

        _ = press(keyCode: KeyCode.rightArrow)
        _ = press(keyCode: KeyCode.rightArrow)
        guard handler.state.segmentState?.focusedIndex == 2 else {
            XCTFail("フォーカスが最終セグメントにあるはず"); return
        }
        guard let seg2 = handler.state.segmentState?.segments[2] else { return }
        _ = press(
            keyCode: KeyCode.enter,
            candidateVisible: true,
            selectedRow: seg2.selectedIndex,
            selectedText: seg2.selectedText
        )
        XCTAssertEqual(handler.db.fetchBoundaryPref(fullReading: "きょうはいい"), ["きょう", "は", "いい"])
    }

    func testBoundaryPrefSavedAfterLlmMultiSegmentManualResize() {
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: BoundaryPrefLLMMockKyouHaii())
        client = MockTextClient()
        typeRomaji("kyouhaii")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else { return }
        handler.applyLLMSegmentResult(text: "今日はイイ")
        guard handler.state.segmentState != nil else { return }

        _ = press(keyCode: KeyCode.leftArrow, modifiers: .shift)
        guard let adjusted = handler.state.segmentState else { return }
        let expectedReadings = adjusted.segments.map(\.reading)
        _ = press(keyCode: KeyCode.enter, candidateVisible: true, selectedRow: 0, selectedText: nil)
        XCTAssertEqual(handler.db.fetchBoundaryPref(fullReading: "きょうはいい"), expectedReadings)
    }

    func testBoundaryPrefReappliedAfterLlmMultiSegmentSave() {
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: BoundaryPrefLLMMockKyouHaii())
        client = MockTextClient()
        typeRomaji("kyouhaii")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else { return }
        handler.applyLLMSegmentResult(text: "今日はイイ")
        guard let ss = handler.state.segmentState else { return }
        _ = press(
            keyCode: KeyCode.enter,
            candidateVisible: true,
            selectedRow: 0,
            selectedText: ss.segments[0].candidates[0]
        )

        _ = press(keyCode: KeyCode.rightArrow)

        typeRomaji("kyouhaii")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode, let ss2 = handler.state.segmentState else {
            XCTFail("保存境界でセグメントモードに再突入するはず"); return
        }
        XCTAssertEqual(ss2.segments.map(\.reading), ["きょう", "は", "いい"])
    }

    func testBoundaryPrefNotSavedAfterLlmSinglePairAlignment() {
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: BoundaryPrefLLMMockTesutoOnePair())
        client = MockTextClient()
        typeRomaji("tesuto")
        XCTAssertEqual(handler.state.composedHiragana, "てすと")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else {
            XCTFail("2 セグメントでセグメントモードに入るはず"); return
        }
        handler.applyLLMSegmentResult(text: "テスト")
        guard let ss = handler.state.segmentState else {
            XCTFail("LLM 適用後 segmentState があるはず"); return
        }
        XCTAssertFalse(ss.isLlmBoundaryInferred, "1 ペアのみのときは多文節推論フラグは false")
        XCTAssertEqual(ss.segments.count, 1)

        let row0 = ss.segments[0].selectedIndex
        let text0 = ss.segments[0].selectedText
        _ = press(
            keyCode: KeyCode.enter,
            candidateVisible: true,
            selectedRow: row0,
            selectedText: text0
        )
        XCTAssertNil(handler.db.fetchBoundaryPref(fullReading: "てすと"))
    }

    func testBoundaryPrefNotSavedAfterLlmFallbackSingleSegmentInsert() {
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: LLMFallbackForcingMockAzoo())
        client = MockTextClient()
        typeRomaji("watashihagakusei")
        _ = press(keyCode: KeyCode.space)
        guard handler.state.isSegmentMode else { return }

        let llm = "私は学生です"
        handler.applyLLMSegmentResult(text: llm)
        XCTAssertEqual(handler.state.segmentState?.segments.first?.candidates.first, llm)

        _ = press(
            keyCode: KeyCode.enter,
            candidateVisible: true,
            selectedRow: 0,
            selectedText: llm
        )
        XCTAssertNil(handler.db.fetchBoundaryPref(fullReading: "わたしはがくせい"))
    }
}

// MARK: - boundary_pref LLM 保存テスト用 AzooKey スタブ

private final class BoundaryPrefLLMMockKyouHaii: AzooKeyConverting, @unchecked Sendable {
    var isZenzaiEnabled: Bool { true }

    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = (hiragana, leftSideContext, richCandidates)
        return []
    }
    func commit(reading: String, text: String) {}

    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        _ = leftSideContext
        switch reading {
        case "きょう": return ["今日"]
        case "は": return ["は"]
        case "いい": return ["いい", "イイ"]
        default: return []
        }
    }

    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])] {
        _ = leftSideContext
        guard hiragana == "きょうはいい" else { return [] }
        return [
            ("きょう", ["今日"]),
            ("は", ["は"]),
            ("いい", ["いい", "イイ"])
        ]
    }
}

private final class BoundaryPrefLLMMockTesutoOnePair: AzooKeyConverting, @unchecked Sendable {
    var isZenzaiEnabled: Bool { false }

    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = (hiragana, leftSideContext, richCandidates)
        return []
    }
    func commit(reading: String, text: String) {}

    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        _ = leftSideContext
        if reading == "てすと" { return ["テスト"] }
        return []
    }

    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])] {
        _ = leftSideContext
        guard hiragana == "てすと" else { return [] }
        return [
            ("て", ["て"]),
            ("すと", ["すと"])
        ]
    }
}
