import XCTest
@testable import KeynacoCore

private final class SegmentRebuildDictMismatchMockAzoo: AzooKeyConverting, @unchecked Sendable {
    var isZenzaiEnabled: Bool { false }
    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = (hiragana, leftSideContext, richCandidates)
        return []
    }
    func requestConversionResult(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool,
        resetEngineSession: Bool
    ) -> AzooKeyConversionResult {
        _ = (leftSideContext, richCandidates, resetEngineSession)
        switch hiragana {
        case "わたしはがくせい":
            return AzooKeyConversionResult(
                mainResults: [AzooKeyClauseCandidate(text: "わたしはがくせい", inputLength: 10)],
                firstClauseResults: [AzooKeyClauseCandidate(text: "わたし", inputLength: 3)]
            )
        case "はがくせい":
            return AzooKeyConversionResult(
                mainResults: [AzooKeyClauseCandidate(text: "はがくせい", inputLength: 7)],
                firstClauseResults: [AzooKeyClauseCandidate(text: "は", inputLength: 1)]
            )
        case "がくせい":
            return AzooKeyConversionResult(
                mainResults: [AzooKeyClauseCandidate(text: "がくせい", inputLength: 5)],
                firstClauseResults: [AzooKeyClauseCandidate(text: "がくせい", inputLength: 5)]
            )
        default:
            return AzooKeyConversionResult(mainResults: [], firstClauseResults: [])
        }
    }
    func commit(reading: String, text: String) {}
    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        _ = leftSideContext
        if reading == "がくせい" {
            return ["がく", "学生"]
        }
        return []
    }
    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])] {
        _ = leftSideContext
        guard hiragana == "わたしはがくせい" || hiragana == "はがくせい" || hiragana == "がくせい" else { return [] }
        switch hiragana {
        case "わたしはがくせい":
            return [("わたし", []), ("は", []), ("がくせい", [])]
        case "はがくせい":
            return [("は", []), ("がくせい", [])]
        case "がくせい":
            return [("がくせい", [])]
        default:
            return []
        }
    }
}

private final class SegmentRebuildPreservedMissingMockAzoo: AzooKeyConverting, @unchecked Sendable {
    var isZenzaiEnabled: Bool { false }
    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = (hiragana, leftSideContext, richCandidates)
        return []
    }
    func requestConversionResult(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool,
        resetEngineSession: Bool
    ) -> AzooKeyConversionResult {
        _ = (leftSideContext, richCandidates, resetEngineSession)
        switch hiragana {
        case "わたしはがくせい":
            return AzooKeyConversionResult(
                mainResults: [AzooKeyClauseCandidate(text: "わたしはがくせい", inputLength: 10)],
                firstClauseResults: [AzooKeyClauseCandidate(text: "わたし", inputLength: 3)]
            )
        case "はがくせい":
            return AzooKeyConversionResult(
                mainResults: [AzooKeyClauseCandidate(text: "はがくせい", inputLength: 7)],
                firstClauseResults: [AzooKeyClauseCandidate(text: "は", inputLength: 1)]
            )
        case "がくせい":
            return AzooKeyConversionResult(
                mainResults: [AzooKeyClauseCandidate(text: "ONLY_INITIAL_SURFACE", inputLength: 5)],
                firstClauseResults: [AzooKeyClauseCandidate(text: "ONLY_INITIAL_SURFACE", inputLength: 5)]
            )
        default:
            return AzooKeyConversionResult(mainResults: [], firstClauseResults: [])
        }
    }
    func commit(reading: String, text: String) {}
    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        _ = leftSideContext
        if reading == "がくせい" {
            return ["がく"]
        }
        return []
    }
    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])] {
        _ = leftSideContext
        guard hiragana == "わたしはがくせい" || hiragana == "はがくせい" || hiragana == "がくせい" else { return [] }
        switch hiragana {
        case "わたしはがくせい":
            return [("わたし", []), ("は", []), ("がくせい", ["ONLY_INITIAL_SURFACE"])]
        case "はがくせい":
            return [("は", []), ("がくせい", ["ONLY_INITIAL_SURFACE"])]
        case "がくせい":
            return [("がくせい", ["ONLY_INITIAL_SURFACE"])]
        default:
            return []
        }
    }
}

final class InputHandlerSegmentTests: InputHandlerTestCase {

    func testGakuseiDesuSpaceSplitsBeforeDesu() {
        typeRomaji("gakuseidesu")
        let (_, action) = press(keyCode: 49)
        XCTAssertTrue(handler.state.isSegmentMode)
        XCTAssertEqual(handler.state.segmentState?.effectiveClauseEnd, 4, "がくせい")
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("候補 .show: \(action)"); return
        }
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertEqual(handler.state.segmentState?.remainingReading, "です")
    }

    func testAnataWaSpaceShowsClauseScopedCandidates() {
        typeRomaji("anataha")
        let (_, action) = press(keyCode: 49)
        XCTAssertTrue(handler.state.isSegmentMode, "Space で文節モードに入る")
        XCTAssertEqual(handler.state.segmentState?.effectiveClauseEnd, 3)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("候補 .show を返すはず: \(action)"); return
        }
        XCTAssertFalse(candidates.isEmpty, "先頭文節の候補が空")
        XCTAssertTrue(
            candidates.contains("貴方") || candidates.contains("あなた"),
            "先頭文節候補に貴方/あなた: \(candidates.prefix(6))"
        )
    }

    func testSpaceEntersSegmentModeWhenMultipleSegments() {
        typeRomaji("watashihagakusei")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        if handler.state.isSegmentMode {
            guard case .show = action else {
                XCTFail("セグメントモード時は .show を返すはず: \(action)"); return
            }
        } else {
            guard case .show = action else {
                XCTFail("単一セグメント時も .show にフォールバックするはず: \(action)"); return
            }
        }
    }

    func testSpaceFallsBackToNormalModeForSingleSegment() {
        type(chars: "a", base: "a")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        guard case .show = action else {
            XCTFail("単一セグメントでも .show にフォールバックするはず: \(action)"); return
        }
    }

    func testSequentialEnterConfirmsOneSegmentAtATime() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode, let ss0 = handler.state.segmentState else {
            XCTFail("文節モードに入るはず"); return
        }
        XCTAssertEqual(ss0.effectiveClauseEnd, 3, "1 文節目: わたし")
        XCTAssertEqual(ss0.clauseReading, "わたし")

        press(keyCode: 36)
        XCTAssertTrue(handler.state.isSegmentMode, "1 文節目確定後も残りがあればセグメントモード継続")
        XCTAssertEqual(client.inserted.joined(), "わたし")
        XCTAssertEqual(handler.state.composedHiragana, "はがくせい")
        XCTAssertGreaterThan(handler.state.segmentState?.effectiveClauseEnd ?? 0, 0)

        while handler.state.isSegmentMode {
            press(keyCode: 36)
        }
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertFalse(client.inserted.joined().isEmpty)
        XCTAssertTrue(client.inserted.joined().hasPrefix("わたし"))
    }

    func testSegmentModeEscapeRestoresComposing() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode else { return }

        let (consumed, action) = press(keyCode: 53)
        XCTAssertTrue(consumed)
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertEqual(handler.state.composedHiragana, "わたしはがくせい")
        XCTAssertTrue(client.inserted.isEmpty)
        guard case .dismiss = action else {
            XCTFail("Escape は .dismiss を返すはず: \(action)"); return
        }
    }

    func testSegmentModeBackspaceExits() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode else { return }

        let (consumed, action) = press(keyCode: 51)
        XCTAssertTrue(consumed)
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertTrue(client.inserted.isEmpty)
        guard case .dismiss = action else {
            XCTFail("Backspace は .dismiss を返すはず: \(action)"); return
        }
    }

    func testSegmentModeRightArrowConfirmsClauseLikeAzooKey() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode else { return }

        let readingBefore = handler.state.segmentState?.current.reading
        press(keyCode: 123) // ← は部分確定しない
        XCTAssertEqual(handler.state.segmentState?.current.reading, readingBefore)

        press(keyCode: 124) // → は AzooKey `.selecting` と同様に部分確定
        XCTAssertFalse(client.inserted.isEmpty, "→ で左端文節が insert されるはず")
        XCTAssertTrue(handler.state.isSegmentMode, "残りがあれば文節選択を継続")
    }

    func testSegmentModeHistoryRecordedPerSegment() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        press(keyCode: 36)
        while handler.state.isSegmentMode {
            press(keyCode: 36)
        }
        XCTAssertFalse(client.inserted.isEmpty)
    }

    func testCommitCompositionInSegmentMode() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode else { return }

        handler.commitComposition(client: client)
        XCTAssertFalse(client.inserted.isEmpty)
        XCTAssertFalse(handler.state.isSegmentMode)
    }

    func testSingleSegmentDoesNotRecordPhrase() {
        type(chars: "a", base: "a")
        press(keyCode: 49)
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "あ")
        XCTAssertFalse(client.inserted.isEmpty)
    }

    func testSegmentResizeExpandShiftRight() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss0 = handler.state.segmentState,
              !ss0.remainingReading.isEmpty else { return }

        let firstReading = ss0.current.reading
        let nextFirst = ss0.remainingReading.first!
        press(keyCode: 124, modifiers: .shift)
        guard let ss = handler.state.segmentState else {
            XCTFail("セグメントモードが維持されるはず"); return
        }
        XCTAssertEqual(ss.current.reading, firstReading + String(nextFirst))
    }

    func testSegmentResizeShrinkShiftLeft() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss0 = handler.state.segmentState,
              ss0.current.reading.count >= 2 else { return }

        let firstReading = ss0.current.reading
        press(keyCode: 123, modifiers: .shift)
        guard let ss = handler.state.segmentState else {
            XCTFail("セグメントモードが維持されるはず"); return
        }
        XCTAssertEqual(ss.current.reading, String(firstReading.dropLast()))
    }

    func testSegmentResizeConfirmAfterResize() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode else { return }

        press(keyCode: 124, modifiers: .shift)
        press(keyCode: 36)
        if handler.state.isSegmentMode {
            while handler.state.isSegmentMode { press(keyCode: 36) }
        }
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertFalse(client.inserted.isEmpty)
    }

    func testSegmentModeSpaceSelectsNextCandidate() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode else { return }

        let (consumed, action) = press(keyCode: 49, candidateVisible: true)
        XCTAssertTrue(consumed)
        XCTAssertTrue(handler.state.isSegmentMode)
        guard case .selectNext = action else {
            XCTFail("セグメントモード中の Space は .selectNext を返すはず: \(action)"); return
        }
    }

    func testHistoryPrefixAppearsInSegmentCandidates() {
        handler.db.recordPrefixes(reading: "にほんごかんきょう", output: "日本語環境")
        let seg = handler.buildSegmentCandidates(
            reading: "にほんご",
            dictCandidates: [],
            prev: nil
        )
        XCTAssertTrue(seg.candidates.contains("日本語環境"))
    }

    func testSequentialConfirmWithMockReSegmentize() {
        setUpWithConverter(SegmentRebuildDictMismatchMockAzoo())
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode else {
            XCTFail("セグメントモードに入るはず"); return
        }
        XCTAssertEqual(handler.state.segmentState?.current.reading, "わたし")

        press(keyCode: 36)
        XCTAssertTrue(handler.state.isSegmentMode)
        XCTAssertEqual(handler.state.segmentState?.current.reading, "は")

        press(keyCode: 36)
        XCTAssertTrue(handler.state.isSegmentMode)
        XCTAssertEqual(handler.state.segmentState?.current.reading, "がくせい")
        XCTAssertEqual(handler.state.segmentState?.current.selectedText, "がくせい")

        press(keyCode: 36)
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertEqual(client.inserted.joined(), "わたしはがくせい")
    }

    func testSequentialConfirmFallbackWhenPreservedSurfaceMissing() {
        setUpWithConverter(SegmentRebuildPreservedMissingMockAzoo())
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode else {
            XCTFail("セグメントモードに入るはず"); return
        }

        press(keyCode: 36)
        press(keyCode: 36)
        guard let ss = handler.state.segmentState else {
            XCTFail("3 文節目までセグメントモード継続"); return
        }
        XCTAssertEqual(ss.current.selectedText, "ONLY_INITIAL_SURFACE")

        press(keyCode: 36)
        XCTAssertEqual(client.inserted.joined(), "わたしはONLY_INITIAL_SURFACE")
    }
}
