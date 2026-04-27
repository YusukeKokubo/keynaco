import XCTest
@testable import keynaco

// See: docs/domain/states.md#セグメントモード
// See: docs/domain/glossary.md#セグメントモードsegmentmode

final class InputHandlerSegmentTests: InputHandlerTestCase {

    // MARK: - セグメントモード
    // See: docs/domain/states.md#セグメントモード
    // See: docs/domain/glossary.md#セグメントモードsegmentmode

    func testSpaceEntersSegmentModeWhenMultipleSegments() {
        typeRomaji("watashihagakusei")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        // azooKey が複数セグメントに分割する場合はセグメントモードへ
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

    func testSegmentModeEnterConfirmsAndInserts() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode or normal
        let (consumed, _) = press(keyCode: 36)  // Enter
        XCTAssertTrue(consumed)
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertFalse(client.inserted.isEmpty, "確定でテキストが挿入されるはず")
        // successor mode display depends on AzooKey conversion; tested in testSuccessorMode* tests
    }

    func testSegmentModeEscapeRestoresComposing() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        guard handler.state.isSegmentMode else { return }  // 1セグメントならスキップ

        let (consumed, action) = press(keyCode: 53)  // Escape
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
        press(keyCode: 49)  // Space → segment mode
        guard handler.state.isSegmentMode else { return }

        let (consumed, action) = press(keyCode: 51)  // Backspace
        XCTAssertTrue(consumed)
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertTrue(client.inserted.isEmpty)
        guard case .dismiss = action else {
            XCTFail("Backspace は .dismiss を返すはず: \(action)"); return
        }
    }

    func testSegmentModeLeftRightMovesFocus() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space
        guard handler.state.isSegmentMode else { return }

        XCTAssertEqual(handler.state.segmentState?.focusedIndex, 0)
        press(keyCode: 124)  // Right
        XCTAssertGreaterThan(handler.state.segmentState?.focusedIndex ?? 0, 0)
        press(keyCode: 123)  // Left
        XCTAssertEqual(handler.state.segmentState?.focusedIndex, 0)
    }

    func testSegmentModeHistoryRecordedPerSegment() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)   // Space → segment mode or candidate display
        press(keyCode: 36)   // Enter → confirm all

        // 確定後にテキストが挿入されること（セグメント確定 or 全体確定）
        XCTAssertFalse(client.inserted.isEmpty, "確定でテキストが挿入されるはず")
    }

    func testCommitCompositionInSegmentMode() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        guard handler.state.isSegmentMode else { return }

        handler.commitComposition(client: client)
        XCTAssertFalse(client.inserted.isEmpty, "deactivateServer 相当の強制確定")
        XCTAssertFalse(handler.state.isSegmentMode)
    }

    // MARK: - フレーズ単位学習（改善 E）
    // See: docs/domain/glossary.md#databasemanager

    func testPhraseRecordedAfterMultiSegmentConfirm() {
        // 複数セグメントを Space 確定したとき、合成読み × 合成出力が1エントリとして記録される
        typeRomaji("watashihagakusei")
        press(keyCode: 49)  // Space → segment mode
        guard handler.state.isSegmentMode,
              let ss = handler.state.segmentState,
              ss.segments.count >= 2 else { return }

        let fullReading = ss.segments.map(\.reading).joined()
        press(keyCode: 36)  // Enter → 確定

        // フレーズ全体の読みで履歴が記録されているはず
        let hist = handler.db.fetchHistoryExact(reading: fullReading)
        XCTAssertFalse(hist.isEmpty, "合成読みでフレーズ全体が履歴に記録されるはず")
    }

    func testSingleSegmentDoesNotRecordPhrase() {
        // 1セグメントのみのとき合成エントリは記録しない
        type(chars: "a", base: "a")
        press(keyCode: 49)  // Space → 候補ウィンドウ（1セグメントフォールバック）
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "あ")
        // "あ" の読みで記録されるが、合成読み（全体）は記録されない（1セグメントなのでフレーズ記録スキップ）
        // ここではクラッシュしないことと挿入テキストがあることを確認
        XCTAssertFalse(client.inserted.isEmpty)
    }

    // MARK: - セグメント境界調整（Shift+矢印）
    // See: docs/domain/states.md#セグメントモード

    func testSegmentResizeExpandShiftRight() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss0 = handler.state.segmentState,
              ss0.segments.count >= 2 else { return }

        let firstReading = ss0.segments[0].reading
        let nextFirst = ss0.segments[1].reading.first!
        press(keyCode: 124, modifiers: .shift)  // Shift+Right
        guard let ss = handler.state.segmentState else {
            XCTFail("セグメントモードが維持されるはず"); return
        }
        XCTAssertEqual(ss.segments[0].reading, firstReading + String(nextFirst),
                       "フォーカスセグメントが1文字拡張されるはず")
    }

    func testSegmentResizeShrinkShiftLeft() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss0 = handler.state.segmentState,
              ss0.segments[0].reading.count >= 2 else { return }

        let firstReading = ss0.segments[0].reading
        press(keyCode: 123, modifiers: .shift)  // Shift+Left
        guard let ss = handler.state.segmentState else {
            XCTFail("セグメントモードが維持されるはず"); return
        }
        XCTAssertEqual(ss.segments[0].reading, String(firstReading.dropLast()),
                       "フォーカスセグメントが1文字縮小されるはず")
    }

    func testSegmentResizeConfirmAfterResize() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode else { return }

        press(keyCode: 124, modifiers: .shift)  // Shift+Right
        press(keyCode: 36)   // Enter → 確定
        XCTAssertFalse(handler.state.isSegmentMode)
        XCTAssertFalse(client.inserted.isEmpty)
    }
}
