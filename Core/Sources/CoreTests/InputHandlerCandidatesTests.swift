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
        handler.leftSideContext = "prefix"
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

    func testUnknownWordShowsKatakanaCandidate() {
        // 未知語（カタカナ・ひらがな以外の候補なし）: カタカナがカタカナセクションに現れる
        setUpWithConverter(SnapStub(["グロトスク", "ぐろとすく"]))
        handler.state.composedHiragana = "ぐろとすく"
        handler.state.pendingRomaji = ""
        let action = handler.buildCandidateList(autoShow: true)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(candidates.contains("グロトスク"), "未知語でもカタカナ候補が表示されるはず")
        XCTAssertTrue(candidates.contains("ぐろとすく"), "ひらがなも表示されるはず")
    }

    func testKnownWordWithZenzaiDoesNotShowKatakanaInMainList() {
        // 実質的な変換候補がある場合: カタカナは主要リストに出ない（既存の仕様を保護）
        setUpWithConverter(SnapStub(["良いのでは", "ヨイノデハ", "よいのでは"], zenzai: true))
        handler.leftSideContext = "prefix"
        handler.state.composedHiragana = "よいのでは"
        handler.state.pendingRomaji = ""
        let action = handler.buildCandidateList(autoShow: true)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertFalse(candidates.contains("ヨイノデハ"), "変換候補がある場合はカタカナを除外")
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

    func testUserDictAppearsInCandidates() {
        handler.db.addUserDict(input: "かいしゃ", output: "Acme Corp")
        typeRomaji("kaisha")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("Acme Corp"), "ユーザー辞書エントリが候補に含まれるはず: \(candidates)")
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

    // MARK: - 低スコア履歴は候補に載せない

    func testLowScoreHistoryExcludedFromCandidates() {
        let t0: Int64 = 2_000_000_000
        handler.db.clock = { t0 }
        let marker = "⌘愛媛ア"
        handler.db.record(input: "あい", output: marker)
        // count=1 かつ age > τ(30日) なら recencyExpr < 0.5
        handler.db.clock = { t0 + 40 * 86400 }
        typeRomaji("ai")
        let (_, action) = press(keyCode: 49)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertFalse(candidates.contains(marker), "低スコア履歴は候補に載せない")
    }

    func testAutoShowShowsWhenOnlyLowScoreHistoryAndAzooKeyExists() {
        let t0: Int64 = 2_010_000_000
        handler.db.clock = { t0 }
        handler.db.record(input: "あい", output: "⌘lowOnlyAutoShow")
        handler.db.clock = { t0 + 40 * 86400 }
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show = action else {
            XCTFail("低スコア履歴のみでも AzooKey があれば autoShow は .show のはず: \(action)"); return
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
