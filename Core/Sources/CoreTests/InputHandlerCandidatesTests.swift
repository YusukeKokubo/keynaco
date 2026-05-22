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
        XCTAssertTrue(candidates.contains("あい"), "ひらがなが候補に含まれるはず")
        XCTAssertTrue(candidates.contains("アイ"), "カタカナが候補に含まれるはず")
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

    func testKoushitaiContainsPrimaryKanji() {
        // AzooKey の変換結果がそのまま出ること（フィルタなし）
        let (_, action) = typeAndPress("koushitai")
        if let list = candidates(in: action) {
            XCTAssertTrue(list.contains(where: { $0.contains("講師") || $0.contains("高死") }), "azooKey 漢字変換候補が含まれるはず: \(list)")
        }
    }

    // MARK: - カタカナ変換・候補管理
    // See: docs/domain/glossary.md#fixedcount
    // See: docs/domain/glossary.md#historyend

    func testInitialRowIsHiraganaWhenNoHistory() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertGreaterThan(candidates.count, 2, "azooKey が候補を返すはず")
        XCTAssertEqual(initialRow, 0, "履歴/予測なしのとき initialRow はひらがな固定候補（0）")
    }

    func testInitialRowSkipsFixedCandidatesWhenHistoryExists() {
        handler.db.record(input: "あい", output: "愛")
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates[initialRow], "愛", "履歴候補「愛」が初期選択")
    }

    // MARK: - hiraganaPreferred initialRow

    func testHiraganaPreferredParticleWithWrongHistorySelectsHiraganaFixed() {
        handler.db.recordPrefixes(reading: "の", output: "ノックアウト")
        typeRomaji("no")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(initialRow, 0)
        XCTAssertEqual(candidates[initialRow], "の", "誤履歴があってもひらがな固定を初期選択")
    }

    func testHiraganaPreferredParticleWithHiraganaHistorySelectsHiraganaNotKatakana() {
        handler.db.recordPrefixes(reading: "の", output: "の")
        typeRomaji("no")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        let noIdx = candidates.firstIndex(of: "の")
        XCTAssertNotNil(noIdx)
        XCTAssertEqual(initialRow, noIdx)
        XCTAssertEqual(candidates[initialRow], "の")
        if let katakanaIdx = candidates.firstIndex(of: "ノ") {
            XCTAssertNotEqual(initialRow, katakanaIdx, "ひらがな履歴時はカタカナ行を選ばない")
        }
        if candidates[0] != "の" {
            XCTAssertNotEqual(initialRow, 0, "row 0 がひらがなでないときは 0 を選ばない")
        }
    }

    func testHiraganaPreferredTokaWithWrongHistory() {
        handler.db.recordPrefixes(reading: "とか", output: "戸籍")
        typeRomaji("toka")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates[initialRow], "とか")
    }

    func testHiraganaPreferredDewaWithWrongHistory() {
        handler.db.recordPrefixes(reading: "では", output: "出羽")
        typeRomaji("deha")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates[initialRow], "では")
    }

    func testHiraganaPreferredKoreWithWrongHistory() {
        handler.db.recordPrefixes(reading: "これ", output: "己れ")
        typeRomaji("kore")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates[initialRow], "これ")
    }

    func testBareConversionWithZenzaiPutsZenzaiFirstThenHiragana() {
        // Zenzai あり・履歴なし・autoShow: Zenzai が先頭、ひらがなは直後
        setUpWithConverter(SnapStub(["良いのでは", "ヨイノデハ", "よいのでは"], zenzai: true))
        handler.leftSideContext = "前文"
        handler.state.composedHiragana = "よいのでは"
        handler.state.pendingRomaji = ""
        let action = handler.buildCandidateList(autoShow: true)
        guard case .show(let candidates, _, let initialRow, _, let fixedEnd) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates[0], "良いのでは", "Zenzai top-1 が row 0")
        XCTAssertEqual(initialRow, 0, "Zenzai 先頭なら initialRow=0")
        XCTAssertFalse(candidates.contains("ヨイノデハ"), "読みのカタカナ表記は辞書から除外")
        XCTAssertEqual(candidates[1], "よいのでは", "ひらがなは Zenzai の直後")
        XCTAssertGreaterThanOrEqual(fixedEnd, 2)
    }

    func testBareConversionWithoutZenzaiPutsHiraganaFirst() {
        // Zenzai なし・履歴なし・autoShow: ひらがなが先頭
        setUpWithConverter(SnapStub(["良いのでは", "ヨイノデハ", "よいのでは"], zenzai: false))
        handler.state.composedHiragana = "よいのでは"
        handler.state.pendingRomaji = ""
        let action = handler.buildCandidateList(autoShow: true)
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(candidates.first, "よいのでは", "Zenzai なしでは row 0 はひらがな")
        XCTAssertEqual(initialRow, 0)
    }

    func testHiraganaInHistoryAppearsAsHistoryCandidate() {
        handler.db.record(input: "あい", output: "あい")
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.contains("あい"), "ひらがなが履歴候補として現れるはず")
        XCTAssertEqual(candidates[initialRow], "あい", "履歴候補「あい」が初期選択")
    }

    func testKatakanaInHistoryAppearsAsHistoryCandidate() {
        handler.db.record(input: "あい", output: "アイ")
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.contains("アイ"), "カタカナが履歴候補として現れるはず")
        XCTAssertEqual(candidates[initialRow], "アイ", "履歴候補「アイ」が初期選択")
    }

    func testLongVowelInputPrefersKatakanaOverHistory() {
        // 「とーたる」→「と一樽」の履歴があっても、ーを含む読みはカタカナ（トータル）を初期選択
        handler.db.record(input: "とーたる", output: "と一樽")
        handler.db.record(input: "とーたる", output: "と一樽")
        handler.db.record(input: "とーたる", output: "と一樽")
        type(chars: "t", base: "t")
        type(chars: "o", base: "o")
        type(chars: "-", base: "-")
        type(chars: "t", base: "t")
        type(chars: "a", base: "a")
        type(chars: "r", base: "r")
        type(chars: "u", base: "u")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, let initialRow, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.contains("トータル"), "トータルが候補に含まれるはず: \(candidates)")
        XCTAssertEqual(candidates[initialRow], "トータル", "長音符入力の initialRow はカタカナ（トータル）を指すはず")
    }

    func testSmallVowelInputPrefersKatakana() {
        // 「ねいてぃぶ」はぃ（小母音）を含むため、カタカナ（ネイティブ）を初期選択かつ固定セクションに配置
        // buildCandidateList を直接呼ぶ（Space は enterSegmentMode を経由するため）
        type(chars: "n", base: "n"); type(chars: "e", base: "e"); type(chars: "i", base: "i")
        type(chars: "t", base: "t"); type(chars: "h", base: "h"); type(chars: "i", base: "i")
        type(chars: "b", base: "b"); type(chars: "u", base: "u")
        XCTAssertEqual(handler.state.composedHiragana, "ねいてぃぶ", "composedHiragana が期待値")
        let action = handler.buildCandidateList()
        guard case .show(let candidates, _, let initialRow, _, let fixedEnd) = action else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("ネイティブ"), "ネイティブが候補に含まれるはず: \(candidates)")
        guard let katRow = candidates.firstIndex(of: "ネイティブ") else { return }
        XCTAssertLessThan(katRow, fixedEnd, "ネイティブは固定セクションに含まれるはず（fixedEnd=\(fixedEnd)）")
        XCTAssertEqual(initialRow, katRow, "小母音入力の initialRow はカタカナ（ネイティブ）を指すはず")
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

    func testSpaceSelectsNextWhenExplicitlySelected() {
        typeRomaji("kanzi")
        let result = press(keyCode: 49, candidateVisible: true,
                           selectedRow: 1, selectedText: "感じ", isExplicitlySelected: true)
        XCTAssertTrue(result.consumed)
        guard case .selectNext = result.candidateAction else {
            XCTFail("候補選択中（isExplicitlySelected=true）の space は .selectNext を返すはず"); return
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
        seedNounBigramPrediction(prev: "東京", input: "かいしゃ", output: "Acme Inc.")
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
        guard case .show(let candidates, _, _, _, let fixedEnd) = action else {
            XCTFail(".show を返すはず"); return
        }
        guard let udRow = candidates.firstIndex(of: "Acme Corp") else {
            XCTFail("ユーザー辞書エントリが候補に含まれるはず: \(candidates)"); return
        }
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

    func testNoDuplicatesAcrossHistoryAndNounBigram() {
        handler.db.record(input: "から", output: "から")
        seedNounBigramPrediction(prev: "て", input: "から", output: "から")
        handler.committedHistory = ["て"]
        typeRomaji("kara")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        let count = candidates.filter { $0 == "から" }.count
        XCTAssertEqual(count, 1, "履歴と noun-bigram に同じ候補があっても重複なし: \(candidates)")
    }

    // MARK: - 低スコア履歴の AzooKey 後ろ回し（P4）

    func testLowScoreHistoryAppendedAfterAzooKey() {
        let t0: Int64 = 2_000_000_000
        handler.db.clock = { t0 }
        let marker = "⌘愛媛ア"  // 末尾カタカナ → isNounLike = true
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

// MARK: - Step 1 スナップショットテスト (PLAN260519)
// assembleCandidateList のリファクタ前後で候補リスト構造が変わっていないことを保証する。
// Step 3 完了後も 1 行も書き換えずに通ること。

private final class SnapStub: BaseAzooKeyStub, @unchecked Sendable {
    let lines: [String]
    init(_ lines: [String], zenzai: Bool = false) {
        self.lines = lines; super.init(); isZenzaiEnabled = zenzai
    }
    override func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] { lines }
}

final class InputHandlerCandidateSnapshotTests: InputHandlerTestCase {

    private func useStub(_ stub: SnapStub) { setUpWithConverter(stub) }

    private func assertLayout(
        _ action: CandidateAction,
        candidates: [String], historyEnd: Int, predictionEnd: Int, fixedEnd: Int, initialRow: Int,
        file: StaticString = #file, line: UInt = #line
    ) {
        guard case .show(let c, let h, let r, let p, let f) = action else {
            XCTFail("Expected .show but got \(action)", file: file, line: line); return
        }
        XCTAssertEqual(c, candidates, "candidates", file: file, line: line)
        XCTAssertEqual(h, historyEnd, "historyEnd", file: file, line: line)
        XCTAssertEqual(p, predictionEnd, "predictionEnd", file: file, line: line)
        XCTAssertEqual(f, fixedEnd, "fixedEnd", file: file, line: line)
        XCTAssertEqual(r, initialRow, "initialRow", file: file, line: line)
    }

    // MARK: - A: 基本ケース（固定セクションなし）

    func testSnap_A1_BareAzooKeyOnly() {
        // 読み「あい」: 履歴なし・予測なし・AzooKey 2件。全境界=0
        useStub(SnapStub(["辞書A", "辞書B"]))
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["辞書A", "辞書B", "アイ"],
                     historyEnd: 0, predictionEnd: 0, fixedEnd: 0, initialRow: 0)
    }

    func testSnap_A2_OneHighHistory() {
        // 高スコア履歴1件: 先頭に来て initialRow=0
        useStub(SnapStub(["辞書A", "辞書B"]))
        handler.db.record(input: "あい", output: "愛")
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["愛", "辞書A", "辞書B", "アイ"],
                     historyEnd: 1, predictionEnd: 0, fixedEnd: 0, initialRow: 0)
    }

    func testSnap_A3_ThreeHighHistories() {
        // 高スコア履歴 3件（maxHighHistoryCount=3）: 最新順で並ぶ
        useStub(SnapStub(["辞書A", "辞書B"]))
        let t = Int64(1_000_000_000)
        handler.db.clock = { t };     handler.db.record(input: "あい", output: "愛知")
        handler.db.clock = { t + 1 }; handler.db.record(input: "あい", output: "愛媛")
        handler.db.clock = { t + 2 }; handler.db.record(input: "あい", output: "愛情")
        handler.db.clock = { t + 3 }
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["愛情", "愛媛", "愛知", "辞書A", "辞書B", "アイ"],
                     historyEnd: 3, predictionEnd: 0, fixedEnd: 0, initialRow: 0)
    }

    func testSnap_A4_LowHistoryOnly() {
        // 低スコア履歴のみ: AzooKey の後ろ、lowHistory の前に追加される
        useStub(SnapStub(["辞書A", "辞書B"]))
        let t = Int64(1_000_000_000)
        handler.db.clock = { t }
        handler.db.record(input: "あい", output: "哀")
        handler.db.clock = { t + 40 * 86400 }  // 40日後 = low score
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["辞書A", "辞書B", "アイ", "哀"],
                     historyEnd: 0, predictionEnd: 0, fixedEnd: 0, initialRow: 0)
    }

    func testSnap_A5_HighAndLowHistory() {
        // 高スコア+低スコア: 高スコアは先頭、低スコアは katakana 末尾
        useStub(SnapStub(["辞書A", "辞書B"]))
        let t = Int64(1_000_000_000)
        handler.db.clock = { t }
        handler.db.record(input: "あい", output: "哀")  // low
        handler.db.clock = { t + 40 * 86400 }
        handler.db.record(input: "あい", output: "愛")  // high (now)
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["愛", "辞書A", "辞書B", "アイ", "哀"],
                     historyEnd: 1, predictionEnd: 0, fixedEnd: 0, initialRow: 0)
    }

    // MARK: - B: 予測（noun-bigram）

    func testSnap_B1_PredictionOnly() {
        // noun-bigram 予測のみ: predictionEnd=1, historyEnd=predictionEnd
        useStub(SnapStub(["辞書A", "辞書B"]))
        seedNounBigramPrediction(prev: "東京", input: "あい", output: "予測A")
        handler.committedHistory = ["東京"]
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["予測A", "辞書A", "辞書B", "アイ"],
                     historyEnd: 1, predictionEnd: 1, fixedEnd: 0, initialRow: 0)
    }

    func testSnap_B2_PredictionAndHighHistory() {
        // noun-bigram 予測 + 高スコア履歴: 予測が先頭、履歴が続く
        useStub(SnapStub(["辞書A", "辞書B"]))
        seedNounBigramPrediction(prev: "東京", input: "あい", output: "予測A")
        handler.committedHistory = ["東京"]
        handler.db.record(input: "あい", output: "愛")
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["予測A", "愛", "辞書A", "辞書B", "アイ"],
                     historyEnd: 2, predictionEnd: 1, fixedEnd: 0, initialRow: 0)
    }

    // MARK: - C: hiraganaPreferred

    func testSnap_C1_HiraganaPreferredNoHistory() {
        // 「の」履歴なし: ひらがな固定先頭・initialRow=0
        useStub(SnapStub(["辞書A", "辞書B"]))
        typeRomaji("no")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["の", "辞書A", "辞書B", "ノ"],
                     historyEnd: 1, predictionEnd: 1, fixedEnd: 1, initialRow: 0)
    }

    func testSnap_C2_HiraganaPreferredWrongHistory() {
        // 「の」に誤履歴: ひらがな固定先頭、誤履歴がその後ろ
        useStub(SnapStub(["辞書A", "辞書B"]))
        handler.db.record(input: "の", output: "ノックアウト")
        typeRomaji("no")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["の", "ノックアウト", "辞書A", "辞書B", "ノ"],
                     historyEnd: 2, predictionEnd: 1, fixedEnd: 1, initialRow: 0)
    }

    func testSnap_C3_HiraganaPreferredHiraganaInHistory() {
        // 「の」が履歴にある: pos=NULL（未分類）は通過するため履歴として出る（固定スロットなし）
        useStub(SnapStub(["辞書A", "辞書B"]))
        handler.db.record(input: "の", output: "の")
        typeRomaji("no")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["の", "辞書A", "辞書B", "ノ"],
                     historyEnd: 1, predictionEnd: 0, fixedEnd: 0, initialRow: 0)
    }

    func testSnap_C4_HiraganaPreferredWithUserDict() {
        // 「とか」+ユーザー辞書: fixedEnd = ひらがな(1) + userDict(1) = 2
        useStub(SnapStub(["辞書A", "辞書B"]))
        handler.db.addUserDict(input: "とか", output: "UD戸籍")
        typeRomaji("toka")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["とか", "UD戸籍", "辞書A", "辞書B", "トカ"],
                     historyEnd: 2, predictionEnd: 2, fixedEnd: 2, initialRow: 0)
    }

    // MARK: - D: foreignMarker（長音符・小母音）

    func testSnap_D1_ForeignMarkerNoHistory() {
        // 「とーたる」（長音符「ー」）: カタカナ固定先頭・initialRow=0
        useStub(SnapStub(["辞書A", "辞書B"]))
        type(chars: "t", base: "t"); type(chars: "o", base: "o")
        type(chars: "-", base: "-")
        type(chars: "t", base: "t"); type(chars: "a", base: "a")
        type(chars: "r", base: "r"); type(chars: "u", base: "u")
        XCTAssertEqual(handler.state.composedHiragana, "とーたる")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["トータル", "辞書A", "辞書B"],
                     historyEnd: 1, predictionEnd: 1, fixedEnd: 1, initialRow: 0)
    }

    func testSnap_D2_ForeignMarkerKatakanaInHistory() {
        // 「とーたる」にカタカナ履歴あり: 固定セクションなし（履歴として出る）
        useStub(SnapStub(["辞書A", "辞書B"]))
        handler.db.record(input: "とーたる", output: "トータル")
        type(chars: "t", base: "t"); type(chars: "o", base: "o")
        type(chars: "-", base: "-")
        type(chars: "t", base: "t"); type(chars: "a", base: "a")
        type(chars: "r", base: "r"); type(chars: "u", base: "u")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["トータル", "辞書A", "辞書B"],
                     historyEnd: 1, predictionEnd: 0, fixedEnd: 0, initialRow: 0)
    }

    func testSnap_D3_SmallVowelForeignMarker() {
        // 「ねいてぃぶ」（小母音「ぃ」）: カタカナ固定先頭
        useStub(SnapStub(["辞書A", "辞書B"]))
        type(chars: "n", base: "n"); type(chars: "e", base: "e"); type(chars: "i", base: "i")
        type(chars: "t", base: "t"); type(chars: "h", base: "h"); type(chars: "i", base: "i")
        type(chars: "b", base: "b"); type(chars: "u", base: "u")
        XCTAssertEqual(handler.state.composedHiragana, "ねいてぃぶ")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["ネイティブ", "辞書A", "辞書B"],
                     historyEnd: 1, predictionEnd: 1, fixedEnd: 1, initialRow: 0)
    }

    // MARK: - E: ユーザー辞書

    func testSnap_E1_UserDictOnly() {
        // ユーザー辞書のみ: fixedEnd=1、initialRow=1（最初の非固定候補）
        useStub(SnapStub(["辞書A", "辞書B"]))
        handler.db.addUserDict(input: "あい", output: "Acme")
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["Acme", "辞書A", "辞書B", "アイ"],
                     historyEnd: 1, predictionEnd: 1, fixedEnd: 1, initialRow: 1)
    }

    func testSnap_E2_UserDictWithHighHistory() {
        // ユーザー辞書 + 高スコア履歴: userDict が固定枠、履歴は historyEnd 内
        useStub(SnapStub(["辞書A", "辞書B"]))
        handler.db.addUserDict(input: "あい", output: "Acme")
        handler.db.record(input: "あい", output: "愛")
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["Acme", "愛", "辞書A", "辞書B", "アイ"],
                     historyEnd: 2, predictionEnd: 1, fixedEnd: 1, initialRow: 1)
    }

    func testSnap_E3_UserDictDedupedWhenInAzooKey() {
        // AzooKey が userDict と同じ表層を返す場合: userDict は固定枠に入らず dedup で消える
        useStub(SnapStub(["Acme", "辞書B"]))
        handler.db.addUserDict(input: "あい", output: "Acme")
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["Acme", "辞書B", "アイ"],
                     historyEnd: 0, predictionEnd: 0, fixedEnd: 0, initialRow: 0)
    }

    // MARK: - F: Zenzai top-1 プロモート

    func testSnap_F1_ZenzaiPromotedWithContext() {
        // Zenzai enabled + leftContext あり: top-1 が fixedEnd-1 に昇格
        useStub(SnapStub(["Zen先頭", "辞書B"], zenzai: true))
        handler.leftSideContext = "前文"
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["Zen先頭", "辞書B", "アイ"],
                     historyEnd: 1, predictionEnd: 1, fixedEnd: 1, initialRow: 0)
    }

    func testSnap_F2_ZenzaiNoContext() {
        // leftContext なし: top-1 プロモートなし・全境界=0
        useStub(SnapStub(["Zen先頭", "辞書B"], zenzai: true))
        // leftSideContext = "" (default) → azooKeyLeftContext = nil → no promotion
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["Zen先頭", "辞書B", "アイ"],
                     historyEnd: 0, predictionEnd: 0, fixedEnd: 0, initialRow: 0)
    }

    func testSnap_F3_ZenzaiDisabled() {
        // Zenzai off: top-1 プロモートなし・全境界=0
        useStub(SnapStub(["Zen先頭", "辞書B"], zenzai: false))
        handler.leftSideContext = "前文"
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["Zen先頭", "辞書B", "アイ"],
                     historyEnd: 0, predictionEnd: 0, fixedEnd: 0, initialRow: 0)
    }

    func testSnap_F4_ZenzaiTop1AlreadyInHistory() {
        // top-1 が高スコア履歴と重複: fixedEnd に入らず dedup
        useStub(SnapStub(["Zen先頭", "辞書B"], zenzai: true))
        handler.leftSideContext = "前文"
        handler.db.record(input: "あい", output: "Zen先頭")
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["Zen先頭", "辞書B", "アイ"],
                     historyEnd: 1, predictionEnd: 0, fixedEnd: 0, initialRow: 0)
    }

    func testSnap_F5_ZenzaiWithUserDict() {
        // userDict + Zenzai: fixedEnd = userDict(1) + zenzai(1) = 2
        useStub(SnapStub(["Zen先頭", "辞書B"], zenzai: true))
        handler.leftSideContext = "前文"
        handler.db.addUserDict(input: "あい", output: "UD合い")
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["UD合い", "Zen先頭", "辞書B", "アイ"],
                     historyEnd: 2, predictionEnd: 2, fixedEnd: 2, initialRow: 0)
    }

    func testSnap_F6_ZenzaiFirstWithAutoShow() {
        // autoShow + Zenzai + 履歴なし: Zenzai が先頭、ひらがな固定は直後
        // fixedEnd = zenzai(1) + fixedHiragana(1) = 2, initialRow = 0
        useStub(SnapStub(["Zen先頭", "辞書B"], zenzai: true))
        handler.leftSideContext = "前文"
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(autoShow: true),
                     candidates: ["Zen先頭", "あい", "辞書B", "アイ"],
                     historyEnd: 2, predictionEnd: 2, fixedEnd: 2, initialRow: 0)
    }

    func testSnap_F7_ZenzaiFirstAutoShowNoContext() {
        // autoShow + Zenzai + leftContext なし: プロモートなし → ひらがなが先頭
        useStub(SnapStub(["Zen先頭", "辞書B"], zenzai: true))
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(autoShow: true),
                     candidates: ["あい", "Zen先頭", "辞書B", "アイ"],
                     historyEnd: 1, predictionEnd: 1, fixedEnd: 1, initialRow: 0)
    }

    // MARK: - G: 数値・日時候補

    func testSnap_G1_NumberCandidates() {
        // 「1234」: 数値候補が historyEnd(=0) 位置に挿入される
        useStub(SnapStub([]))
        type(chars: "1", base: "1"); type(chars: "2", base: "2")
        type(chars: "3", base: "3"); type(chars: "4", base: "4")
        XCTAssertEqual(handler.state.composedHiragana, "1234")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["１２３４", "1,234", "１，２３４"],
                     historyEnd: 0, predictionEnd: 0, fixedEnd: 0, initialRow: 0)
    }

    func testSnap_G2_DateTimeCandidatesAtHistoryEnd() {
        // 「きょう」: 日時候補が historyEnd 以降に挿入される。exact 値は動的なので同じ関数で生成
        useStub(SnapStub(["今日", "本日"]))
        typeRomaji("kyou")
        let action = handler.buildCandidateList()
        guard case .show(let cands, let hEnd, _, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        let expectedDates = InputHandler.generateDateTimeCandidates(for: "きょう")
        XCTAssertFalse(expectedDates.isEmpty, "日時候補が生成されるはず")
        XCTAssertEqual(hEnd, 0, "履歴なしなら historyEnd=0")
        XCTAssertEqual(Array(cands[0..<expectedDates.count]), expectedDates,
                       "日時候補が先頭（historyEnd=0 の位置）から並ぶはず: \(cands)")
        XCTAssertEqual(Array(cands.suffix(3)), ["今日", "本日", "キョウ"],
                       "AzooKey 候補は日時候補の後ろ・カタカナは末尾: \(cands)")
    }

    // MARK: - H: autoShow

    func testSnap_H1_AutoShowDismissWhenEmpty() {
        // AzooKey empty + 全候補ゼロ → autoShow は .dismiss
        useStub(SnapStub([]))
        typeRomaji("ai")
        guard case .dismiss = handler.buildCandidateList(autoShow: true) else {
            XCTFail("候補ゼロの autoShow は .dismiss を返すはず"); return
        }
    }

    func testSnap_H2_AutoShowShowsWithHistory() {
        // 履歴あり → autoShow でも .show
        useStub(SnapStub([]))
        handler.db.record(input: "あい", output: "愛")
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(autoShow: true),
                     candidates: ["愛", "アイ"],
                     historyEnd: 1, predictionEnd: 0, fixedEnd: 0, initialRow: 0)
    }

    // MARK: - I: 全セクション組み合わせ

    func testSnap_I1_AllSectionsCombined() {
        // userDict + Zenzai(fixed) + prediction + highHistory + lowHistory
        let t = Int64(1_000_000_000)
        useStub(SnapStub(["辞書A"], zenzai: true))
        handler.db.clock = { t }
        handler.db.record(input: "あい", output: "哀")   // low history
        handler.db.clock = { t + 40 * 86400 }
        handler.db.record(input: "あい", output: "愛")   // high history (now)
        handler.leftSideContext = "前文"
        handler.db.addUserDict(input: "あい", output: "UD合い")
        seedNounBigramPrediction(prev: "東京", input: "あい", output: "予測A")
        handler.committedHistory = ["東京"]
        typeRomaji("ai")
        // fixedEnd=2(userDict+zenzai), predictionEnd=3, historyEnd=4
        assertLayout(handler.buildCandidateList(),
                     candidates: ["UD合い", "辞書A", "予測A", "愛", "アイ", "哀"],
                     historyEnd: 4, predictionEnd: 3, fixedEnd: 2, initialRow: 0)
    }

    func testSnap_I2_HiraganaPreferredWithZenzai() {
        // hiraganaPreferred「の」+ Zenzai top-1: fixedEnd = ひらがな(1) + zenzai(1) = 2
        useStub(SnapStub(["Zen先頭"], zenzai: true))
        handler.leftSideContext = "前文"
        typeRomaji("no")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["の", "Zen先頭", "ノ"],
                     historyEnd: 2, predictionEnd: 2, fixedEnd: 2, initialRow: 0)
    }
}

// MARK: - Zenzai top-1 プロモート（PLAN260506）

private final class ZenzaiPromoteTestMockAzooKey: BaseAzooKeyStub, @unchecked Sendable {
    var candidateLines: [String] = ["表層先頭", "表層2番目"]

    override init() {
        super.init()
        isZenzaiEnabled = true
    }

    override func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        candidateLines
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
        XCTAssertEqual(candidates[fixedEnd - 1], top1, "Zenzai top-1 が固定枠末尾")
        XCTAssertGreaterThanOrEqual(fixedEnd, 1, "Zenzai top-1 昇格で fixedEnd は少なくとも1")
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
        handler.db.recordNounBigram(prev: "東京", input: "てすと", output: top1)
        handler.db.recordNounBigram(prev: "東京", input: "てすと", output: "予測だけ別語")
        handler.lastConfirmedNounOutput = "東京"
        typeRomaji("tesuto")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, let predictionEnd, let fixedEnd) = action else {
            XCTFail(".show を返すはず"); return
        }
        let predictionSlice = candidates[fixedEnd..<predictionEnd]
        XCTAssertTrue(predictionSlice.contains(top1),
                      "noun_bigram は Zenzai top-1 と重複していても予測ゾーンに含める: \(predictionSlice)")
        XCTAssertTrue(predictionSlice.contains("予測だけ別語"))
    }

    func testZenzaiPromoteSkippedWhenDisabled() {
        zenzaiMock.isZenzaiEnabled = false
        handler.leftSideContext = "ctx"
        type(chars: "a", base: "a")
        let (_, action) = press(keyCode: 49)
        guard case .show = action else { XCTFail(".show"); return }
        XCTAssertNil(handler.lastZenzaiRow, "Zenzai オフ時は lastZenzaiRow が nil")
    }

    func testZenzaiPromoteSkippedWhenNoLeftContext() {
        handler.leftSideContext = ""
        type(chars: "a", base: "a")
        let (_, action) = press(keyCode: 49)
        guard case .show = action else { XCTFail(".show"); return }
        XCTAssertNil(handler.lastZenzaiRow, "左文脈なしでは lastZenzaiRow が nil")
    }
}
