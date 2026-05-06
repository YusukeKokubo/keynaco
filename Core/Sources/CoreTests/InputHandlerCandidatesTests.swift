import XCTest
@testable import KeynacoCore

// See: docs/domain/states.md#候補選択中
// See: docs/domain/glossary.md#fixedcount
// See: docs/domain/glossary.md#historyend
// See: docs/domain/scenarios.md#s-02-候補選択と右矢印確定

final class InputHandlerCandidatesTests: InputHandlerTestCase {

    // MARK: - スペースで候補表示
    // See: docs/domain/states.md#候補選択中

    func testSpaceWithHiraganaShowsCandidates() {
        type(chars: "a", base: "a")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("スペースで .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("あ"))
    }

    func testSpaceWithNothingPassesThrough() {
        XCTAssertFalse(press(keyCode: 49).consumed)
    }

    func testKatakanaAppearsInCandidatesOnSpace() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates[0], "あい", "先頭はひらがなのはず")
        XCTAssertEqual(candidates[1], "アイ", "2番目はカタカナのはず")
    }

    func testKatakanaInCandidatesWhenSpacePressed() {
        type(chars: "a", base: "a")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.contains("ア"), "カタカナが候補に含まれるはず")
    }

    // MARK: - 漢字変換（azooKey）

    func testTanoshiiConvertsToKanji() {
        typeRomaji("tanoshii")
        XCTAssertEqual(client.markedText, "たのしい")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("Space で .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("楽しい"), "「楽しい」が候補に含まれるはず: \(candidates)")
    }

    // MARK: - カタカナ変換・候補管理
    // See: docs/domain/glossary.md#fixedcount
    // See: docs/domain/glossary.md#historyend

    func testInitialRowSkipsFixedCandidatesWhenCandidatesExist() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertGreaterThan(candidates.count, 2, "azooKey が候補を返すはず")
        XCTAssertEqual(initialRow, 2, "initialRow はひらがな・カタカナの後（2）")
    }

    func testHiraganaInHistoryAppearsAsHistoryCandidate() {
        handler.db.record(input: "あい", output: "あい")
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates[0], "アイ", "カタカナが固定位置0番")
        XCTAssertEqual(candidates[1], "あい", "ひらがなが履歴エントリ（固定位置でなく）")
        XCTAssertEqual(initialRow, 1, "固定候補はカタカナの1件のみ")
    }

    func testKatakanaInHistoryAppearsAsHistoryCandidate() {
        handler.db.record(input: "あい", output: "アイ")
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates[0], "あい", "ひらがなが固定位置0番")
        XCTAssertEqual(candidates[1], "アイ", "カタカナが履歴エントリ（固定位置でなく）")
        XCTAssertEqual(initialRow, 1, "固定候補はひらがなの1件のみ")
    }

    func testReturnCommitsVisuallySelectedCandidateWithoutExplicitNav() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 2, selectedText: "愛")
        XCTAssertEqual(client.inserted, ["愛"], "Enter は視覚的に選択されている候補を確定する")
    }

    func testTypingDoesNotCommitWhenNotExplicitlySelected() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        type(chars: "k", base: "k", candidateVisible: true, selectedRow: 2, selectedText: "愛")
        XCTAssertTrue(client.inserted.isEmpty, "↑↓ なしで文字入力しても候補を確定しない")
        XCTAssertEqual(client.markedText, "あいk")
    }

    func testSpaceDuringCandidatesFallsBackToShowForSingleSegment() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 49, candidateVisible: true, selectedRow: 0)
        XCTAssertTrue(result.consumed)
        guard case .show = result.candidateAction else {
            XCTFail("単一セグメントのスペースは .show にフォールバックするはず: \(result.candidateAction)"); return
        }
    }

    func testSelectKatakanaCandidate() {
        typeRomaji("ai")
        press(keyCode: 36, candidateVisible: true, selectedText: "アイ", isExplicitlySelected: true)
        XCTAssertEqual(client.inserted, ["アイ"], "カタカナ候補を確定できるはず")
    }

    func testSpaceWithUnknownReadingShowsHiraganaAndKatakana() {
        type(chars: "u", base: "u")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.contains("う"))
        XCTAssertTrue(candidates.contains("ウ"))
    }

    // MARK: - 候補ウィンドウ中のキーナビゲーション
    // See: docs/domain/states.md#候補選択中
    // See: docs/domain/scenarios.md#s-02-候補選択と右矢印確定

    func testDownArrowSelectsNext() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 125, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        guard case .selectNext = result.candidateAction else {
            XCTFail("↓ キーは .selectNext を返すはず"); return
        }
    }

    func testUpArrowSelectsPrev() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 126, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        guard case .selectPrev = result.candidateAction else {
            XCTFail("↑ キーは .selectPrev を返すはず"); return
        }
    }

    func testTabSelectsNext() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 48, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        guard case .selectNext = result.candidateAction else {
            XCTFail("Tab キーは .selectNext を返すはず"); return
        }
    }

    func testShiftTabSelectsPrev() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 48, modifiers: .shift, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        guard case .selectPrev = result.candidateAction else {
            XCTFail("Shift+Tab は .selectPrev を返すはず"); return
        }
    }

    func testDownArrowPassesThroughWithoutCandidates() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 125, candidateVisible: false)
        XCTAssertFalse(result.consumed, "候補なし時の ↓ はスルーするはず")
    }

    func testUpArrowPassesThroughWithoutCandidates() {
        type(chars: "a", base: "a")
        let result = press(keyCode: 126, candidateVisible: false)
        XCTAssertFalse(result.consumed, "候補なし時の ↑ はスルーするはず")
    }

    func testRightArrowDuringCandidateCommitsHiragana() {
        // "か" を組成して候補ウィンドウに漢字候補「花」が選択されている状態
        typeRomaji("ka")
        let result = press(keyCode: 124, candidateVisible: true, selectedText: "花")
        XCTAssertTrue(result.consumed)
        // 漢字ではなくひらがなが確定される
        XCTAssertEqual(client.inserted, ["か"])
        XCTAssertTrue(handler.state.composingText.isEmpty, "確定後は組成バッファが空になるはず")
    }

    func testRightArrowDuringCandidateIgnoresSelectedCandidate() {
        // 候補が明示的に選択されていても右矢印はひらがなを確定する
        typeRomaji("nihon")
        let result = press(keyCode: 124, candidateVisible: true,
                           selectedRow: 2, selectedText: "日本", isExplicitlySelected: true)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["にほん"])
    }

    // MARK: - 候補ウィンドウ中のバックスペース・Escape

    func testBackspaceDuringCandidateDisplayDismissesWhenSingleCharRemains() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let result = press(keyCode: 51, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "あ")
        guard case .dismiss = result.candidateAction else {
            XCTFail("1文字になったら .dismiss するはず: \(result.candidateAction)"); return
        }
    }

    func testBackspaceDuringCandidateDisplayRefreshesWhenMultipleCharsRemain() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        type(chars: "u", base: "u")
        let result = press(keyCode: 51, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "あい")
        guard case .show = result.candidateAction else {
            XCTFail("2文字以上残るなら .show を返すはず: \(result.candidateAction)"); return
        }
    }

    func testEscapeDuringCandidateDisplayClearsComposition() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let result = press(keyCode: 53, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "")
        XCTAssertTrue(client.inserted.isEmpty)
        guard case .dismiss = result.candidateAction else {
            XCTFail("候補表示中の Escape は .dismiss を返すはず"); return
        }
    }

    // MARK: - autoShow: 候補ゼロ時は表示しない
    // See: docs/domain/glossary.md#autoshow

    func testAutoShowDismissesWhenNoCandidates() {
        // ASCII 組成（履歴ゼロ・辞書スキップ）で文字入力 → buildCandidateList(autoShow:true) は .dismiss
        let (consumed, action) = type(chars: "X", base: "x", modifiers: .shift)
        XCTAssertTrue(consumed)
        guard case .dismiss = action else {
            XCTFail("履歴・辞書・予測候補がゼロなら autoShow は .dismiss を返すはず: \(action)"); return
        }
    }

    // MARK: - historyEnd 境界: Shift+Delete の削除可否
    // See: docs/domain/glossary.md#historyend
    // See: docs/domain/scenarios.md#s-06-shiftdelete-で履歴削除

    func testShiftDeleteInsideHistoryEndDeletesCandidate() {
        // selectedRow < historyEnd → .deleteSelected を返す
        typeRomaji("ka")
        let ctx = CandidateContext(isVisible: true, selectedRow: 1, selectedText: nil,
                                   isExplicitlySelected: true, historyEnd: 2)
        let (_, action) = handler.handle(keyCode: KeyCode.backspace, characters: nil, baseCharacters: nil,
                                          modifiers: .shift, candidate: ctx, client: client)
        guard case .deleteSelected = action else {
            XCTFail("historyEnd 未満の Shift+Delete は .deleteSelected を返すはず: \(action)"); return
        }
    }

    func testShiftDeleteOutsideHistoryEndDoesNothing() {
        // selectedRow >= historyEnd → .none を返す（AzooKey 専用候補は削除不可）
        typeRomaji("ka")
        let ctx = CandidateContext(isVisible: true, selectedRow: 5, selectedText: nil,
                                   isExplicitlySelected: true, historyEnd: 2)
        let (_, action) = handler.handle(keyCode: KeyCode.backspace, characters: nil, baseCharacters: nil,
                                          modifiers: .shift, candidate: ctx, client: client)
        guard case .none = action else {
            XCTFail("historyEnd 以降の Shift+Delete は .none を返すはず: \(action)"); return
        }
        XCTAssertTrue(client.inserted.isEmpty, "削除不可なので確定テキストは挿入されないはず")
    }

    // MARK: - ユーザー辞書候補

    func testUserDictAppearsBeforePredictions() {
        handler.db.addUserDict(input: "かいしゃ", output: "Acme Corp")
        handler.db.recordBigram(prev: "東京", input: "かいしゃ", output: "Acme Inc.")
        handler.committedHistory = ["東京"]
        typeRomaji("kaisha")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        let udIdx = candidates.firstIndex(of: "Acme Corp")
        let bgIdx = candidates.firstIndex(of: "Acme Inc.")
        XCTAssertNotNil(udIdx, "ユーザー辞書エントリが候補に含まれるはず: \(candidates)")
        if let u = udIdx, let b = bgIdx {
            XCTAssertLessThan(u, b, "ユーザー辞書エントリが予測候補より前に来るはず")
        }
    }

    func testUserDictFixedEndProtectsEntries() {
        handler.db.addUserDict(input: "かいしゃ", output: "Acme Corp")
        typeRomaji("kaisha")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, let initialRow, _, let fixedEnd) = action else {
            XCTFail(".show を返すはず"); return
        }
        guard let udRow = candidates.firstIndex(of: "Acme Corp") else {
            XCTFail("ユーザー辞書エントリが候補に含まれるはず: \(candidates)"); return
        }
        XCTAssertGreaterThanOrEqual(udRow, initialRow, "ユーザー辞書行は initialRow 以降")
        XCTAssertLessThan(udRow, fixedEnd, "ユーザー辞書行は fixedEnd より前（削除不可ゾーン）")
    }

    func testUserDictExactMatchOnly() {
        handler.db.addUserDict(input: "かいしゃ", output: "Acme Corp")
        typeRomaji("kais")  // "かいs" — 前方一致（未完成）
        let (_, action) = press(keyCode: 49)
        if case .show(let candidates, _, _, _, _) = action {
            XCTAssertFalse(candidates.contains("Acme Corp"), "前方一致ではユーザー辞書エントリが現れないはず")
        }
    }

    // MARK: - 重複排除

    func testNoDuplicateCandidatesWhenTrigramAndBigramOverlap() {
        // tri-gram と bi-gram に同じ候補があっても候補リストに重複が出ないこと
        handler.db.recordBigram(prev: "東京", input: "に", output: "に")
        handler.db.recordTrigram(prev2: "昨日", prev1: "東京", input: "に", output: "に")
        handler.committedHistory = ["昨日", "東京"]
        typeRomaji("ni")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        let count = candidates.filter { $0 == "に" }.count
        XCTAssertEqual(count, 1, "同一候補は重複なく1件のみ現れるはず: \(candidates)")
    }

    func testNoDuplicatesAcrossHistoryAndBigram() {
        // 履歴と bi-gram に同じ候補があっても重複なし
        handler.db.record(input: "から", output: "から")
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        handler.committedHistory = ["て"]
        typeRomaji("kara")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        let count = candidates.filter { $0 == "から" }.count
        XCTAssertEqual(count, 1, "履歴と bi-gram に同じ候補があっても重複なし: \(candidates)")
    }

    func testTrigramCandidateAppearsBeforeBigramOnlyCandidate() {
        // tri-gram 候補は bi-gram のみの候補より上位
        handler.db.recordBigram(prev: "東京", input: "から", output: "から")
        handler.db.recordTrigram(prev2: "昨日", prev1: "東京", input: "に", output: "に")
        handler.committedHistory = ["昨日", "東京"]
        typeRomaji("ni")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, let historyEnd, _, let predictionEnd, _) = action else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        let niIdx = candidates.prefix(predictionEnd).firstIndex(of: "に")
        XCTAssertNotNil(niIdx, "tri-gram 由来「に」が予測ゾーンに含まれるはず: \(candidates)")
    }

    // MARK: - 低スコア履歴の AzooKey 後ろ回し（P4）

    func testLowScoreHistoryAppendedAfterAzooKey() {
        let t0: Int64 = 2_000_000_000
        handler.db.clock = { t0 }
        let marker = "⌘P4LowScore"
        handler.db.record(input: "あい", output: marker)
        // count=1 かつ age > τ(30日) なら recencyExpr < 0.5
        handler.db.clock = { t0 + 40 * 86400 }
        typeRomaji("ai")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains(marker), "低スコアも候補に含まれるはず")
        XCTAssertEqual(candidates.last, marker, "低スコア履歴はリスト末尾（AzooKey・数値・日時の後）")
    }

    func testAutoShowShowsWhenOnlyLowScoreHistoryAndAzooKeyExists() {
        let t0: Int64 = 2_010_000_000
        handler.db.clock = { t0 }
        handler.db.record(input: "あい", output: "⌘lowOnlyAutoShow")
        handler.db.clock = { t0 + 40 * 86400 }
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show = action else {
            XCTFail("高スコア 0 でも履歴行が残り AzooKey があれば autoShow は .show のはず: \(action)"); return
        }
    }

    // MARK: - 日時候補

    func testKyouIncludesDateCandidates() {
        typeRomaji("kyou")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains { $0.contains("-") }, "ISO日付が候補に含まれるはず: \(candidates)")
        XCTAssertTrue(candidates.contains { $0.hasSuffix("日") }, "日本語日付が候補に含まれるはず")
    }
}

// MARK: - Zenzai top-1 プロモート（PLAN260506）

private final class ZenzaiPromoteTestMockAzooKey: AzooKeyConverting, @unchecked Sendable {
    var candidateLines: [String] = ["表層先頭", "表層2番目"]
    var isZenzaiEnabled = true

    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = hiragana
        _ = leftSideContext
        _ = richCandidates
        return candidateLines
    }

    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        _ = (reading, leftSideContext)
        return []
    }

    func commit(reading: String, text: String) { _ = (reading, text) }

    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])] {
        _ = (hiragana, leftSideContext)
        return []
    }
}

final class InputHandlerZenzaiPromoteTests: InputHandlerTestCase {
    private var zenzaiMock: ZenzaiPromoteTestMockAzooKey!

    override func setUp() {
        super.setUp()
        zenzaiMock = ZenzaiPromoteTestMockAzooKey()
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: zenzaiMock)
    }

    func testZenzaiPromotedTop1AfterUserDictIncreasesFixedEnd() {
        let top1 = zenzaiMock.candidateLines[0]
        handler.leftSideContext = "左文脈"
        type(chars: "a", base: "a")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, let fixedEnd) = action else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertEqual(candidates[fixedEnd - 1], top1, "ユーザー辞書直後の 1 行が top-1")
        XCTAssertGreaterThanOrEqual(fixedEnd, 3, "ひらがな+カタカナ固定2 + プロモート1 で fixedEnd は少なくとも3")
    }

    func testZenzaiPromotedRowIsBelowFixedEndForShiftDelete() {
        handler.leftSideContext = "ctx"
        type(chars: "a", base: "a")
        let (_, action) = press(keyCode: 49)
        guard case .show(_, _, _, _, let fixedEnd) = action else {
            XCTFail(".show を返すはず"); return
        }
        let promotedRow = fixedEnd - 1
        XCTAssertLessThan(promotedRow, fixedEnd, "プロモート行は Shift+Delete 可能帯の外（index < fixedEnd）")
    }

    func testZenzaiPromotedTop1SingleOccurrenceAsideFromHistoryDup() {
        let top1 = zenzaiMock.candidateLines[0]
        handler.leftSideContext = "ctx"
        type(chars: "a", base: "a")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates.filter { $0 == top1 }.count, 1, "辞書ブロックに top-1 が重複して現れない（履歴二重は未設定のため全体でも1回）")
    }

    func testZenzaiPromotedTop1ExcludedFromPredictionBlockWhenBigramMatches() {
        let top1 = "予測と同じ"
        zenzaiMock.candidateLines = [top1, "辞書だけ"]
        handler.leftSideContext = "前文"
        handler.committedHistory = ["東京"]
        handler.db.recordBigram(prev: "東京", input: "てすと", output: top1)
        handler.db.recordBigram(prev: "東京", input: "てすと", output: "予測だけ別語")
        typeRomaji("tesuto")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, let predictionEnd, let fixedEnd) = action else {
            XCTFail(".show を返すはず"); return
        }
        let predictionSlice = candidates[fixedEnd..<predictionEnd]
        XCTAssertFalse(predictionSlice.contains(top1), "予測ゾーンに top-1 と同じ表層を出さない: \(predictionSlice)")
    }

    func testZenzaiPromoteSkippedWhenDisabled() {
        let top1 = zenzaiMock.candidateLines[0]
        zenzaiMock.isZenzaiEnabled = false
        handler.leftSideContext = "ctx"
        type(chars: "a", base: "a")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, let fixedEnd) = action else {
            XCTFail(".show"); return
        }
        XCTAssertNotEqual(candidates[fixedEnd - 1], top1, "Zenzai オフ時は top-1 を固定位置に挿入しない")
    }

    func testZenzaiPromoteSkippedWhenNoLeftContext() {
        let top1 = zenzaiMock.candidateLines[0]
        handler.leftSideContext = ""
        type(chars: "a", base: "a")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, let fixedEnd) = action else {
            XCTFail(".show"); return
        }
        XCTAssertNotEqual(candidates[fixedEnd - 1], top1, "左文脈なしでは固定位置に top-1 を置かない")
    }
}
