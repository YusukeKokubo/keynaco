import XCTest
@testable import keynaco

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

    // MARK: - pendingRomaji 先読み予測
    // 注: ひらがな末尾の単語を確定後（bi-gram なし → isSuccessorMode=false）に bi-gram を事後記録する
    // ことで、確定時には Successor モードに入らず、その後の先読みをテストできる

    func testPendingPreviewShowsCandidatesOnFirstChar() {
        // bi-gram 学習済みで k を入力 → .show + isSuccessorMode = true
        typeRomaji("te")
        press(keyCode: 36)  // 「て」を確定（bi-gram なし → Successor モードなし）
        handler.db.recordBigram(prev: "て", input: "から", output: "から")  // 事後に記録
        XCTAssertFalse(handler.isSuccessorMode)
        let (_, action) = type(chars: "k", base: "k")
        XCTAssertTrue(handler.isSuccessorMode, "先読み候補ありで isSuccessorMode になるはず")
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("bi-gram 学習済みで k → .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("から"), "学習済みの「から」が候補に含まれるはず")
    }

    func testPendingPreviewNExcluded() {
        // n は ん との曖昧さがあるため先読み対象外
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        let (_, action) = type(chars: "n", base: "n")
        guard case .dismiss = action else {
            XCTFail("n は先読み対象外なので .dismiss を返すはず: \(action)"); return
        }
        XCTAssertFalse(handler.isSuccessorMode, "n では isSuccessorMode に入らないはず")
        XCTAssertEqual(handler.state.pendingRomaji, "n", "pendingRomaji = 'n' のまま残るはず")
    }

    func testPendingPreviewNoBigramDismisses() {
        // bi-gram 未学習で k → .dismiss、pendingRomaji が残る
        typeRomaji("te")
        press(keyCode: 36)
        let (_, action) = type(chars: "k", base: "k")
        guard case .dismiss = action else {
            XCTFail("bi-gram 未学習で k → .dismiss を返すはず: \(action)"); return
        }
        XCTAssertFalse(handler.isSuccessorMode, "候補ゼロなら isSuccessorMode に入らないはず")
        XCTAssertEqual(handler.state.pendingRomaji, "k", "pendingRomaji = 'k' のまま残るはず")
    }

    func testPendingPreviewElectronSafetySetMarkedText() {
        // 先読み後の markedText が candidates[0]（空でない）であること
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        type(chars: "k", base: "k")
        XCTAssertFalse(client.markedText.isEmpty, "Electron 対策: markedText が空でないはず")
    }

    func testPendingPreviewSpaceConfirms() {
        // 先読み → Space → confirmSuccessor が呼ばれ bigram が記録される
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        type(chars: "k", base: "k")
        XCTAssertTrue(handler.isSuccessorMode)
        press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "から")
        XCTAssertFalse(handler.isSuccessorMode, "Space 確定後は isSuccessorMode が解除されるはず")
        XCTAssertEqual(client.inserted.last, "から", "「から」が確定されるはず")
    }

    func testPendingPreviewEscapeCancels() {
        // 先読み → Escape → isSuccessorMode = false
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        type(chars: "k", base: "k")
        XCTAssertTrue(handler.isSuccessorMode)
        press(keyCode: 53)
        XCTAssertFalse(handler.isSuccessorMode, "Escape で isSuccessorMode が解除されるはず")
    }

    func testPendingPreviewCancelledByNonMatchingKeyContinuesRomaji() {
        // 先読み → マッチしないキーでキャンセル → pendingRomaji が残り連続組成できる
        // 例: k 先読み → u → k+u=く になる（t+u=つ と同様の原理）
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        type(chars: "k", base: "k")  // 先読み → isSuccessorMode = true、pendingRomaji = "k"
        XCTAssertTrue(handler.isSuccessorMode)
        let (_, action) = type(chars: "u", base: "u")  // Successor キャンセル → k+u=く
        XCTAssertFalse(handler.isSuccessorMode, "u でキャンセル後は isSuccessorMode = false")
        XCTAssertEqual(client.markedText, "く", "先読みキャンセル後に k+u=く になるはず（pendingRomaji が保持される）")
    }

    func testPendingPreviewConfirmedClearsPendingRomaji() {
        // 先読み → Space 確定 → pendingRomaji がクリアされ次の入力が単独で組成される
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        type(chars: "k", base: "k")  // 先読み
        press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "から")  // Space 確定
        XCTAssertFalse(handler.isSuccessorMode)
        type(chars: "t", base: "t")
        type(chars: "u", base: "u")
        XCTAssertEqual(client.markedText, "つ", "先読み確定後に t+u=つ として組成されるはず")
    }

    func testPendingPreviewEscapePreservesRomajiInMarkedText() {
        // 先読み → Escape → pendingRomaji が markedText に表示されて続きを入力できる
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        type(chars: "k", base: "k")  // 先読み → pendingRomaji = "k"
        press(keyCode: 53)  // Escape → applyMarkedText で "k" を表示
        XCTAssertEqual(client.markedText, "k", "Escape 後に pendingRomaji が markedText に残るはず")
        let (_, action) = type(chars: "a", base: "a")  // k+a=か
        XCTAssertEqual(client.markedText, "か", "Escape 後に続けて a を入力すると k+a=か になるはず")
    }

    // MARK: - pendingRomaji 先読み予測（f/j/c キー）

    func testPendingPreviewWithFKeyMatches() {
        // f → romajiToInitialKana["f"] = ["ふ"]
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "ふう", output: "風")
        let (_, action) = type(chars: "f", base: "f")
        XCTAssertTrue(handler.isSuccessorMode, "f キーで先読み候補あれば isSuccessorMode になるはず")
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("f キー先読み → .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("風"), "「ふ」行の bigram 候補が含まれるはず")
    }

    func testPendingPreviewWithJKeyMatches() {
        // j → romajiToInitialKana["j"] = ["じ"]
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "じゆう", output: "自由")
        let (_, action) = type(chars: "j", base: "j")
        XCTAssertTrue(handler.isSuccessorMode, "j キーで先読み候補あれば isSuccessorMode になるはず")
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("j キー先読み → .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("自由"), "「じ」行の bigram 候補が含まれるはず")
    }

    func testPendingPreviewWithCKeyMatchesKaAndChiRows() {
        // c → romajiToInitialKana["c"] = ["か","き","く","け","こ","ち"]
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "ちかく", output: "近く")  // ち行
        handler.db.recordBigram(prev: "て", input: "かれ", output: "彼")    // か行
        let (_, action) = type(chars: "c", base: "c")
        XCTAssertTrue(handler.isSuccessorMode)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("c キー先読み → .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("近く") || candidates.contains("彼"),
                      "「ち」または「か」行の bigram 候補が含まれるはず: \(candidates)")
    }

    func testPendingPreviewNExclusionContinuesAsNormalRomaji() {
        // n は先読み除外 → pendingRomaji = "n" が残り n+i=に と組成できる
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "にほんご", output: "日本語")
        type(chars: "n", base: "n")
        XCTAssertFalse(handler.isSuccessorMode, "n では先読みに入らないはず")
        XCTAssertEqual(handler.state.pendingRomaji, "n")
        type(chars: "i", base: "i")
        XCTAssertEqual(client.markedText, "に", "n+i → に として組成されるはず")
        XCTAssertTrue(handler.state.pendingRomaji.isEmpty)
    }

    func testPendingPreviewTrigramPrioritizedInPreview() {
        // buildPendingCandidateList で tri-gram 候補が bigram のみの候補より先に来る
        typeRomaji("kinou")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "昨日")
        press(keyCode: 53)
        typeRomaji("toukyou")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        press(keyCode: 53)
        handler.db.recordBigram(prev: "東京", input: "とさん", output: "都産")
        handler.db.recordTrigram(prev2: "昨日", prev1: "東京", input: "いった", output: "行った")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("先読みで .show を返すはず: \(action)"); return
        }
        let idxItta = candidates.firstIndex(of: "行った")
        let idxTosan = candidates.firstIndex(of: "都産")
        XCTAssertNotNil(idxItta, "tri-gram 候補「行った」が含まれるはず: \(candidates)")
        if let i = idxItta, let t = idxTosan {
            XCTAssertLessThan(i, t, "tri-gram 由来の候補が bigram のみの候補より上位に来るはず")
        }
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
