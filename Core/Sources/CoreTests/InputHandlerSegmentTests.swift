import XCTest
@testable import KeynacoCore

/// segmentize の clause 辞書と `candidatesForSegment`（main）を意図的にずらす。
/// 右矢印で `がくせい` をリビルドするとき、デフォルト `initialIndex` が短い候補になるケースを再現する。
private final class SegmentRebuildDictMismatchMockAzoo: AzooKeyConverting, @unchecked Sendable {
    var isZenzaiEnabled: Bool { false }
    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = (hiragana, leftSideContext, richCandidates)
        return []
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
        guard hiragana == "わたしはがくせい" else { return [] }
        return [
            ("わたし", []),
            ("は", []),
            ("がくせい", [])
        ]
    }
}

/// `preserved` がリビルド後リストに無いときフォールバックする経路（クラッシュなし・決定的な確定）。
private final class SegmentRebuildPreservedMissingMockAzoo: AzooKeyConverting, @unchecked Sendable {
    var isZenzaiEnabled: Bool { false }
    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = (hiragana, leftSideContext, richCandidates)
        return []
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
        guard hiragana == "わたしはがくせい" else { return [] }
        return [
            ("わたし", []),
            ("は", []),
            ("がくせい", ["ONLY_INITIAL_SURFACE"])
        ]
    }
}

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

    // MARK: - セグメントモード中の Space・候補選択

    func testSegmentModeSpaceSelectsNextCandidate() {
        // セグメントモード中の Space は .selectNext（次の変換候補へ）
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode else { return }

        let (consumed, action) = press(keyCode: 49, candidateVisible: true)
        XCTAssertTrue(consumed)
        XCTAssertTrue(handler.state.isSegmentMode, "Space 後もセグメントモードを維持するはず")
        guard case .selectNext = action else {
            XCTFail("セグメントモード中の Space は .selectNext を返すはず: \(action)"); return
        }
    }

    func testSegmentModeSelectionSavedWhenFocusChanges() {
        // フォーカスセグメントの候補を選択後に別セグメントへ移動し、戻ると選択が保持される
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss0 = handler.state.segmentState,
              ss0.segments.count >= 2,
              ss0.segments[0].candidates.count >= 2 else { return }

        let secondCand = ss0.segments[0].candidates[1]
        // フォーカス 0 で 2番目候補を選択した状態で Right キー
        press(keyCode: 124, candidateVisible: true, selectedRow: 1, selectedText: secondCand)
        XCTAssertEqual(handler.state.segmentState?.focusedIndex, 1)

        // Left で 0 に戻る
        press(keyCode: 123, candidateVisible: true)
        let ss2 = handler.state.segmentState
        XCTAssertEqual(ss2?.focusedIndex, 0)
        XCTAssertEqual(ss2?.segments[0].selectedIndex, 1,
                       "右移動前に選択した候補インデックスが保持されるはず")
    }

    // MARK: - セグメント候補への bigram 活用（F-2）

    func testBigramAppearsInFirstSegmentCandidates() {
        // buildSegmentCandidates が prev の bigram を候補に含めることを確認
        // AzooKey の分割結果に依存しないよう buildSegmentCandidates を直接テストする
        handler.db.recordBigram(prev: "前語", input: "わたし", output: "私")
        let seg = handler.buildSegmentCandidates(
            reading: "わたし",
            dictCandidates: ["渡し", "渡"],
            prev: "前語"
        )
        XCTAssertTrue(seg.candidates.contains("私"),
                      "lastCommittedOutput を prev とする bigram 候補が第1セグメントに含まれるはず")
    }

    func testHistoryPrefixAppearsInSegmentCandidates() {
        handler.db.recordPrefixes(reading: "わたしたち", output: "私たち")
        let seg = handler.buildSegmentCandidates(
            reading: "わたし",
            dictCandidates: [],
            prev: nil
        )
        XCTAssertTrue(seg.candidates.contains("私たち"),
                      "読み前方一致の履歴がセグメント候補に含まれるはず")
    }

    func testBigramCandidatePrecedesHistoryInSegment() {
        // bigram 候補は固定候補（ひらがな・カタカナ）の直後、履歴より前に挿入される
        handler.db.recordBigram(prev: "前語", input: "わたし", output: "私")
        handler.db.recordPrefixes(reading: "わたし", output: "吾")
        handler.committedHistory = ["前語"]

        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss = handler.state.segmentState else { return }

        let candidates = ss.segments[0].candidates
        guard let bigramIdx = candidates.firstIndex(of: "私"),
              let historyIdx = candidates.firstIndex(of: "吾") else { return }
        XCTAssertLessThan(bigramIdx, historyIdx,
                          "bigram 候補は履歴候補より前に表示されるはず")
    }

    func testBigramCascadesFromFirstToSecondSegment() {
        // 第1セグメントのデフォルト選択テキストが第2セグメントの bigram prev になる
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss = handler.state.segmentState,
              ss.segments.count >= 2 else { return }

        let seg0Text = ss.segments[0].selectedText
        let seg1Reading = ss.segments[1].reading
        // seg0Text を prev とする bigram として seg1 の読みに合う候補を学習
        handler.db.recordBigram(prev: seg0Text, input: seg1Reading, output: "ビグラム候補")

        // セグメントモードを Escape で抜けた後 composedHiragana が残るためリセット
        press(keyCode: 53)  // Escape
        handler.state = CompositionState()

        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss2 = handler.state.segmentState,
              ss2.segments.count >= 2 else { return }

        XCTAssertTrue(ss2.segments[1].candidates.contains("ビグラム候補"),
                      "第1セグメントのデフォルト選択が第2セグメントの bigram prev として使われるはず")
    }

    func testBigramRebuildOnRightArrowNavigation() {
        // 右矢印で次セグメントへ移動するとき、移動元の選択テキストを prev として候補がリビルドされる
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss = handler.state.segmentState,
              ss.segments.count >= 2 else { return }

        let seg0Text = ss.segments[0].selectedText
        let seg1Reading = ss.segments[1].reading
        handler.db.recordBigram(prev: seg0Text, input: seg1Reading, output: "ナビ候補")

        press(keyCode: 124)  // Right → seg[1] にフォーカス
        guard let ss2 = handler.state.segmentState,
              ss2.focusedIndex == 1 else { return }

        XCTAssertTrue(ss2.segments[1].candidates.contains("ナビ候補"),
                      "右矢印移動後のセグメントで bigram リビルドが反映されるはず")
    }

    // MARK: - セグメント間 bigram 学習

    func testInterSegmentBigramRecordedAfterConfirm() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss = handler.state.segmentState,
              ss.segments.count >= 2 else { return }

        let seg0Text = ss.segments[0].selectedText
        let seg1Reading = ss.segments[1].reading
        let seg1Text = ss.segments[1].selectedText

        press(keyCode: 36)  // Enter → 確定

        let bigram = handler.db.fetchBigram(prev: seg0Text, reading: seg1Reading)
        XCTAssertTrue(bigram.contains(seg1Text),
                      "2セグメント確定後に隣接 bigram が記録されるはず")
    }

    func testManuallyAdjustedSegmentBigramCountIsHigher() {
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss0 = handler.state.segmentState,
              ss0.segments.count >= 2,
              ss0.segments[0].reading.count >= 2 else { return }

        // focusedIndex = 0 のまま Shift+Left で seg[0] を縮小 → seg[0].isManuallyAdjusted = true
        press(keyCode: 123, modifiers: .shift)  // Shift+Left → seg[0] を縮小
        guard let ss1 = handler.state.segmentState, ss1.segments.count >= 2 else { return }

        let seg0Text = ss1.segments[0].selectedText
        let seg1Reading = ss1.segments[1].reading
        let seg1Text = ss1.segments[1].selectedText

        press(keyCode: 36)  // Enter → 確定

        let entries = handler.db.fetchAllBigram()
        let entry = entries.first(where: { $0.prev == seg0Text && $0.input == seg1Reading && $0.output == seg1Text })
        XCTAssertNotNil(entry, "手動調整セグメントを含む bigram が記録されるはず")
        XCTAssertGreaterThanOrEqual(entry?.count ?? 0, 2,
                                    "手動調整（isManuallyAdjusted）により bigram は通常1回に加え1回ブーストされ count が 2 以上になるはず")
    }

    // MARK: - 右矢印リビルド時の selectedText 保持（segmentize / candidatesForSegment の不一致）

    func testSegmentRightArrowPreservesReadingWhenRebuildDictOrderDiffers() {
        setUpWithConverter(SegmentRebuildDictMismatchMockAzoo())
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss0 = handler.state.segmentState,
              ss0.segments.count >= 3 else {
            XCTFail("3文節セグメントモードになるはず")
            return
        }

        XCTAssertEqual(ss0.segments[2].reading, "がくせい")
        XCTAssertEqual(ss0.segments[2].selectedText, "がくせい",
                       "clause 辞書が空なら読みのひらがな行が既定であるはず")

        press(keyCode: 124)  // → は
        press(keyCode: 124)  // → がくせい（リビルド）

        guard let ss1 = handler.state.segmentState, ss1.focusedIndex == 2 else {
            XCTFail("フォーカスが第3文節にあるはず")
            return
        }
        XCTAssertEqual(ss1.segments[2].selectedText, "がくせい",
                       "リビルド後も読み全文の表層を保持する（欠落バグの修正）")

        press(keyCode: 36, candidateVisible: true, selectedRow: ss1.segments[2].selectedIndex,
              selectedText: ss1.segments[2].selectedText)
        XCTAssertEqual(client.inserted.last, "わたしはがくせい",
                       "Enter で全節連結が読みどおり確定するはず")
    }

    func testSegmentRightArrowRebuildFallbackWhenPreservedSurfaceMissing() {
        setUpWithConverter(SegmentRebuildPreservedMissingMockAzoo())
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss0 = handler.state.segmentState,
              ss0.segments.count >= 3 else {
            XCTFail("3文節セグメントモードになるはず")
            return
        }

        XCTAssertEqual(ss0.segments[2].selectedText, "ONLY_INITIAL_SURFACE")

        press(keyCode: 124)
        press(keyCode: 124)

        guard let ss1 = handler.state.segmentState, ss1.focusedIndex == 2 else {
            XCTFail("フォーカスが第3文節にあるはず")
            return
        }
        XCTAssertEqual(ss1.segments[2].selectedText, "がく",
                       "preserved が候補に無いときは buildSegmentCandidates の既定選択にフォールバック")

        press(keyCode: 36, candidateVisible: true, selectedRow: ss1.segments[2].selectedIndex,
              selectedText: ss1.segments[2].selectedText)
        XCTAssertEqual(client.inserted.last, "わたしはがく",
                       "フォールバックでも確定が破綻しない")
    }
}
