import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

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
        guard let payload = action.showPayload else {
            XCTFail("スペースで .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(payload.candidates.contains("あ"))
    }

    func testSpaceWithNothingPassesThrough() {
        XCTAssertFalse(press(keyCode: 49).consumed)
    }

    func testKatakanaAppearsInCandidatesOnSpace() {
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let (_, action) = press(keyCode: 49)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(payload.candidates.contains("あい"), "ひらがなが候補に含まれるはず")
        XCTAssertTrue(payload.candidates.contains("アイ"), "カタカナが候補に含まれるはず")
    }

    // MARK: - 漢字変換（azooKey）

    /// 組成中 + 候補表示では marked text が選択行に追従する（`InputController` 経路）。
    func testMarkedTextFollowsSelectedRowWhileComposing_kanzi() {
        typeRomaji("kanzi")
        let showAction = handler.buildCandidateList(trigger: .explicit)
        applyCandidateAction(showAction)
        guard let first = handler.candidateSession.selectedText else {
            XCTFail("候補選択行がない"); return
        }
        assertMarkedText(first, "Space 後の marked text は選択行と一致するはず")

        let ctx = handler.candidateSession.makeContext()
        let (_, downAction) = handleAndApply(keyCode: KeyCode.downArrow, candidate: ctx)
        guard let second = handler.candidateSession.selectedText else {
            XCTFail("↓ 後の選択行がない"); return
        }
        XCTAssertNotEqual(first, second, "↓ で別候補に移るはず")
        assertMarkedText(second, "↓ 後の marked text は選択行と一致するはず")
    }

    func testTanoshiiConvertsToKanji() {
        typeRomaji("tanoshii")
        XCTAssertEqual(client.markedText, "たのしい")
        let (consumed, action) = press(keyCode: 49)
        XCTAssertTrue(consumed)
        guard let payload = action.showPayload else {
            XCTFail("Space で .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(payload.candidates.contains("楽しい"), "「楽しい」が候補に含まれるはず: \(payload.candidates)")
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
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertGreaterThan(payload.candidates.count, 2, "azooKey が候補を返すはず")
        XCTAssertEqual(handler.candidateSession.selectedRow, 0)
    }

    func testInitialRowSkipsFixedCandidatesWhenHistoryExists() {
        handler.db.record(input: "あい", output: "愛")
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let (_, action) = press(keyCode: 49)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(payload.candidates[0], "愛", "スコア順先頭の履歴候補が初期選択")
    }

    // MARK: - row 0 score order

    func testHiraganaPreferredParticleWithWrongHistorySelectsHiraganaFixed() {
        handler.db.recordPrefixes(reading: "の", output: "ノックアウト")
        typeRomaji("no")
        let (_, action) = press(keyCode: 49)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(payload.candidates[0], "の", "誤履歴があってもひらがな固定を初期選択")
    }

    func testHiraganaPreferredParticleWithHiraganaHistorySelectsHiraganaNotKatakana() {
        handler.db.recordPrefixes(reading: "の", output: "の")
        typeRomaji("no")
        let (_, action) = press(keyCode: 49)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(payload.candidates[0], "の")
        if let katakanaIdx = payload.candidates.firstIndex(of: "ノ") {
            XCTAssertNotEqual(0, katakanaIdx, "ひらがな履歴時はカタカナ行を row 0 にしない")
        }
    }

    func testHiraganaPreferredTokaWithWrongHistory() {
        handler.db.recordPrefixes(reading: "とか", output: "戸籍")
        typeRomaji("toka")
        let (_, action) = press(keyCode: 49)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(payload.candidates[0], "とか")
    }

    func testHiraganaPreferredDewaWithWrongHistory() {
        handler.db.recordPrefixes(reading: "では", output: "出羽")
        typeRomaji("deha")
        let (_, action) = press(keyCode: 49)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(payload.candidates[0], "では")
    }

    func testHiraganaPreferredKoreWithWrongHistory() {
        handler.db.recordPrefixes(reading: "これ", output: "己れ")
        typeRomaji("kore")
        let (_, action) = press(keyCode: 49)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(payload.candidates[0], "これ")
    }

    func testAzooKeyKatakanaPassesThroughDictSection() {
        // AzooKey がカタカナ表記を返したらそのまま辞書セクションに出る。
        // 既知語（しゃつ→シャツ など）はこの経路で表示される。
        setUpWithConverter(SnapStub(["しゃつ", "謝通門", "シャツ", "洋袗"]))
        handler.state.composedHiragana = "しゃつ"
        handler.state.pendingRomaji = ""
        let action = handler.buildCandidateList(trigger: .whileTyping)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(payload.candidates.contains("シャツ"),
                      "AzooKey が返したカタカナは辞書セクションに出るはず: \(payload.candidates)")
    }

    func testSingleAzooKeyCandidateIsInitialRow() {
        // AzooKey 候補が1件だけのとき、その候補が初期フォーカスになる。
        setUpWithConverter(SnapStub(["今回のことは誤解である"]))
        handler.state.composedHiragana = "こんかいのことはごかいである"
        handler.state.pendingRomaji = ""
        let action = handler.buildCandidateList(trigger: .whileTyping)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertEqual(payload.fixedEnd, 0)
        XCTAssertEqual(payload.candidates, ["今回のことは誤解である"])
    }

    func testHiraganaInHistoryAppearsAsHistoryCandidate() {
        handler.db.record(input: "あい", output: "あい")
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(payload.candidates.contains("あい"), "ひらがなが履歴候補として現れるはず")
        XCTAssertEqual(payload.candidates[0], "あい", "スコア順先頭の履歴候補が初期選択")
    }

    func testKatakanaInHistoryAppearsAsHistoryCandidate() {
        handler.db.record(input: "あい", output: "アイ")
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        XCTAssertTrue(payload.candidates.contains("アイ"), "カタカナが履歴候補として現れるはず")
        XCTAssertEqual(payload.candidates[0], "アイ", "スコア順先頭の履歴候補が初期選択")
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
        XCTAssertEqual(client.markedText, "あいk", "子音打鍵で候補を閉じたあとは pending を marked に出す")
    }

    /// 打鍵中に AzooKey が自動表示した候補（`isExplicitlySelected=false`）上の Space は
    /// `.selectNext` ではなく `.explicit` リビルドにする。Zenzai が Z1 を推した候補を素通りして
    /// Z2 が確定してしまう事故を防ぐため（[docs/rejected.md] / 2026-06-19 修正）。
    func testSpaceDuringAutoShownCandidatesRebuildsExplicit() {
        typeRomaji("kanzi")
        applyCandidateAction(handler.buildCandidateList(trigger: .whileTyping))
        XCTAssertFalse(handler.candidateSession.isExplicitlySelected,
                       "whileTyping 表示は isExplicitlySelected=false が前提")
        let ctx = handler.candidateSession.makeContext()
        let (consumed, action) = handleAndApply(
            keyCode: KeyCode.space, characters: " ", baseCharacters: " ", candidate: ctx
        )
        XCTAssertTrue(consumed)
        guard case .show = action else {
            XCTFail("自動表示中の Space は .explicit リビルドで .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(handler.candidateSession.isExplicitlySelected,
                      "明示変換要求として処理されたので isExplicitlySelected=true になる")
    }

    /// 一度ユーザーが明示選択した（Space / ↓ 等）あとの Space は通常通り `.selectNext`。
    /// `isExplicitlySelected=true` を経た候補窓では次候補移動が期待される挙動。
    func testSpaceAfterExplicitSelectionSelectsNext() {
        typeRomaji("kanzi")
        applyCandidateAction(handler.buildCandidateList(trigger: .explicit))
        XCTAssertTrue(handler.candidateSession.isExplicitlySelected,
                      "explicit 表示は isExplicitlySelected=true が前提")
        let before = handler.candidateSession.candidates
        let ctx = handler.candidateSession.makeContext()
        let (consumed, action) = handleAndApply(
            keyCode: KeyCode.space, characters: " ", baseCharacters: " ", candidate: ctx
        )
        XCTAssertTrue(consumed)
        guard case .selectNext = action else {
            XCTFail("明示選択後の Space は .selectNext のはず: \(action)"); return
        }
        XCTAssertEqual(handler.candidateSession.candidates, before,
                       "明示選択後の Space でリストを差し替えないはず")
    }

    func testSelectKatakanaCandidate() {
        typeRomaji("ai")
        press(keyCode: 36, candidateVisible: true, selectedText: "アイ", isExplicitlySelected: true)
        XCTAssertEqual(client.inserted, ["アイ"], "カタカナ候補を確定できるはず")
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
        XCTAssertFalse(handler.state.isComposing, "確定後は組成バッファが空になるはず")
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

    func testBackspaceDuringCandidateDisplayKeepsCandidatesWhenSingleCharRemains() {
        // 旧挙動: 2 char passive → BS → 1 char で .dismiss していた（state.backspace() の `>=2` 閾値）。
        // 新挙動: composedHiragana が残っている限り .whileTyping で rebuild する。
        // 「BS で候補が突然消える」体感を避けるため、1 char passive 候補を維持する。
        type(chars: "a", base: "a")
        type(chars: "i", base: "i")
        let result = press(keyCode: 51, candidateVisible: true)
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "あ")
        guard case .show = result.candidateAction else {
            XCTFail("1 char に縮んでも .show を返すはず: \(result.candidateAction)"); return
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
        // ASCII 組成（履歴ゼロ・辞書スキップ）で文字入力 → whileTyping は .dismiss
        let (consumed, action) = type(chars: "X", base: "x", modifiers: .shift)
        XCTAssertTrue(consumed)
        guard case .dismiss = action else {
            XCTFail("履歴・辞書・予測候補がゼロなら whileTyping は .dismiss を返すはず: \(action)"); return
        }
    }

    /// **不変条件回帰テスト**: pre-build dismiss（reading が機能語）は通らないが、
    /// 履歴で row 0 が機能語 text に押し上げられた場合の post-build dismiss を pin。
    /// pre/post で同じ `isBuiltinFunctionalWord` predicate を使っとる前提が崩れると失敗する。
    func testWhileTypingDismissesWhenRow0TextIsFunctionalWordViaHistory() {
        setUpWithConverter(BaseAzooKeyStub())  // AzooKey 候補ゼロで history を確実に row 0 にする
        // reading "あ" は builtin でない / 出力 "の" は builtin。
        for _ in 0..<10 { handler.db.record(input: "あ", output: "の") }

        let (_, action) = type(chars: "a", base: "a")
        guard case .dismiss = action else {
            XCTFail(
                "row 0 text が機能語なら whileTyping は dismiss されるはず（post-build dismiss）: \(action)"
            ); return
        }
    }

    // MARK: - candidateSources: Shift+Delete の削除可否

    func testShiftDeleteOnHistorySourceDeletesCandidate() {
        typeRomaji("ka")
        let ctx = CandidateContext(
            isVisible: true, selectedRow: 1, selectedText: nil,
            isExplicitlySelected: true,
            candidateSources: [.historyExact, .historyPrefix]
        )
        let (_, action) = handler.handle(keyCode: KeyCode.backspace, characters: nil, baseCharacters: nil,
                                          modifiers: .shift, candidate: ctx, client: client)
        guard case .deleteSelected = action else {
            XCTFail("history source の Shift+Delete は .deleteSelected を返すはず: \(action)"); return
        }
    }

    func testShiftDeleteOnDictionarySourceDoesNothing() {
        typeRomaji("ka")
        let ctx = CandidateContext(
            isVisible: true, selectedRow: 0, selectedText: nil,
            isExplicitlySelected: true,
            candidateSources: [.azooKey(rank: 0), .azooKey(rank: 1)]
        )
        let (_, action) = handler.handle(keyCode: KeyCode.backspace, characters: nil, baseCharacters: nil,
                                          modifiers: .shift, candidate: ctx, client: client)
        guard case .none = action else {
            XCTFail("辞書 source の Shift+Delete は .none を返すはず: \(action)"); return
        }
        XCTAssertTrue(client.inserted.isEmpty, "削除不可なので確定テキストは挿入されないはず")
    }

    /// **不変条件回帰テスト（PLAN260718）**: 組成中の Shift+Delete で履歴を消した後、
    /// 同じ読みのリビルドが `localSourcesCache` の古いソースを再利用して
    /// 削除済み候補が復活しないこと（`invalidateLocalSourcesCache` の呼び忘れ検知）。
    func testShiftDeleteDoesNotResurrectHistoryOnSameReadingRebuild() {
        setUpWithConverter(BaseAzooKeyStub())  // AzooKey 候補ゼロで履歴を確実に候補へ出す
        for _ in 0..<3 { handler.db.record(input: "かい", output: "下位") }
        typeRomaji("kai")

        // explicit ビルドで localSourcesCache に履歴込みソースが載る
        let first = applyCandidateAction(handler.buildCandidateList(trigger: .explicit))
        XCTAssertTrue(first.showPayload?.candidates.contains("下位") ?? false, "前提: 履歴候補が出とるはず")

        // 「下位」の行まで選択を移してから Shift+Delete 経路（.deleteSelected）を通す
        var moves = 0
        while handler.candidateSession.selectedText != "下位", moves < 10 {
            handleAndApply(keyCode: KeyCode.downArrow)
            moves += 1
        }
        XCTAssertEqual(handler.candidateSession.selectedText, "下位", "前提: 削除対象行を選択できるはず")
        applyCandidateAction(.deleteSelected)

        let rebuilt = handler.buildCandidateList(trigger: .explicit)
        XCTAssertFalse(
            rebuilt.showPayload?.candidates.contains("下位") ?? false,
            "削除した履歴が同読みリビルドで復活しないはず: \(rebuilt.showPayload?.candidates ?? [])"
        )
    }

    // MARK: - ユーザー辞書候補

    func testUserDictAppearsInCandidates() {
        handler.db.addUserDict(input: "かいしゃ", output: "Acme Corp")
        typeRomaji("kaisha")
        let (_, action) = press(keyCode: 49)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertTrue(payload.candidates.contains("Acme Corp"), "ユーザー辞書エントリが候補に含まれるはず: \(payload.candidates)")
    }

    func testUserDictShiftDeleteDoesNothing() {
        handler.db.addUserDict(input: "かいしゃ", output: "Acme Corp")
        typeRomaji("kaisha")
        let (_, showAction) = press(keyCode: 49)
        guard let payload = showAction.showPayload,
              let udRow = payload.candidates.firstIndex(of: "Acme Corp") else {
            XCTFail(".show を返すはず"); return
        }
        let ctx = CandidateContext(
            isVisible: true,
            selectedRow: udRow,
            selectedText: "Acme Corp",
            isExplicitlySelected: true,
            candidateSources: payload.candidateSources
        )
        let (_, action) = handler.handle(
            keyCode: KeyCode.backspace, characters: nil, baseCharacters: nil,
            modifiers: .shift, candidate: ctx, client: client
        )
        guard case .none = action else {
            XCTFail("ユーザー辞書行の Shift+Delete は .none を返すはず: \(action)"); return
        }
    }

    func testUserDictExactMatchOnly() {
        handler.db.addUserDict(input: "かいしゃ", output: "Acme Corp")
        typeRomaji("kais")  // "かいs" — 前方一致（未完成）
        let (_, action) = press(keyCode: 49)
        if let payload = action.showPayload {
            XCTAssertFalse(payload.candidates.contains("Acme Corp"), "前方一致ではユーザー辞書エントリが現れないはず")
        }
    }

    /// A1 後: pos/lcid 未設定のユーザー辞書 prefix は `.unknown`（5 モーラ必要）で弾かれる。
    func testUserDictPrefixFocus_requiresPosClassification() {
        let marker = "⌘UD東京未分類"
        handler.db.addUserDict(input: "とうき", output: marker)
        typeRomaji("toukyo")
        let action = handler.buildCandidateList(trigger: .whileTyping)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertFalse(
            payload.candidates.contains(marker),
            "pos/lcid なしでは userDict prefix focus に載らない: \(payload.candidates)"
        )
    }

    /// ユーザー辞書登録時の pos/lcid 書き込み後は prefix focus が効く（PLAN260617 根本対処）。
    func testUserDictPrefixFocus_afterPosClassification() {
        let marker = "⌘UD東京名詞"
        handler.db.addUserDict(input: "とうき", output: marker)
        handler.db.upsertPOSClassification(
            output: marker, reading: "とうき", pos: "noun", lcid: 1293
        )
        typeRomaji("toukyo")
        let action = handler.buildCandidateList(trigger: .whileTyping)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertTrue(
            payload.candidates.contains(marker),
            "名詞 lcid 設定後は userDict prefix focus に載る: \(payload.candidates)"
        )
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
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertFalse(payload.candidates.contains(marker), "低スコア履歴は候補に載せない")
    }

    func testAutoShowShowsWhenOnlyLowScoreHistoryAndAzooKeyExists() {
        let t0: Int64 = 2_010_000_000
        handler.db.clock = { t0 }
        handler.db.record(input: "あい", output: "⌘lowOnlyAutoShow")
        handler.db.clock = { t0 + 40 * 86400 }
        type(chars: "a", base: "a")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show = action else {
            XCTFail("低スコア履歴のみでも AzooKey があれば whileTyping は .show のはず: \(action)"); return
        }
    }

    // MARK: - exactMatchHighHistory のスコア判定

    /// 「よう→要件」が DB に直接あり「ようけん→要件」が高スコード prefix として存在する場合、
    /// fetchHistoryScoredMerged の prefix SUM スコアが「要件」に混入して
    /// exactMatchHighHistory の先頭に入ってしまうバグの回帰テスト。
    func testExactMatchHighHistoryUsesExactScoreNotPrefixSumScore() {
        setUpWithConverter(BaseAzooKeyStub())

        // よう→用: count=8（高スコア完全一致）
        for _ in 0..<8 { handler.db.record(input: "よう", output: "用") }
        // よう→要件: count=1（完全一致として DB に直接存在するが低カウント）
        handler.db.record(input: "よう", output: "要件")
        // ようけん→要件: count=10（高スコード prefix。GROUP BY output の SUM で「要件」のスコアを底上げする）
        for _ in 0..<10 { handler.db.record(input: "ようけん", output: "要件") }

        typeRomaji("you")
        let action = handler.buildCandidateList(trigger: .whileTyping)

        guard let payload = action.showPayload else {
            XCTFail("candidates should be shown: \(action)"); return
        }
        XCTAssertEqual(
            payload.candidates[0], "用",
            "「よう→用」が最高スコアの完全一致なので初期選択は「用」のはず。"
            + "「ようけん→要件」の prefix SUM が混入して「要件」が選ばれてはいけない。"
            + "candidates=\(payload.candidates)"
        )
    }

    /// 打鍵中: 2 モーラ時点では未分類 prefix 履歴（5 モーラ必要）は載らず exact が先頭。
    func testPrefixFocusBlocksHighScorePrefixAtTwoMoraWhileTyping() {
        setUpWithConverter(BaseAzooKeyStub())

        for _ in 0..<30 {
            handler.db.record(input: "じょうほうきょうゆう", output: "情報共有")
        }
        for _ in 0..<3 {
            handler.db.record(input: "じょう", output: "上")
        }

        typeRomaji("jou")
        let action = handler.buildCandidateList(trigger: .whileTyping)

        guard let payload = action.showPayload else {
            XCTFail("candidates should be shown: \(action)"); return
        }
        XCTAssertEqual(
            payload.candidates[0], "上",
            "2m では unknown 扱いの prefix 履歴より exact が row 0: \(payload.candidates)"
        )
        XCTAssertFalse(
            payload.candidates.contains("情報共有"),
            "閾値未満の prefix 履歴は whileTyping リストから除外: \(payload.candidates)"
        )
    }

    /// 高スコア前方一致履歴が低スコア exact より先頭に来る（打鍵中・閾値充足時）。
    func testHighScorePrefixHistoryPromotedOverExactMatchWhileTyping() {
        setUpWithConverter(BaseAzooKeyStub())

        for _ in 0..<30 {
            handler.db.record(input: "じょうほうきょうゆう", output: "情報共有")
        }
        for _ in 0..<3 {
            handler.db.record(input: "じょう", output: "上")
        }

        typeRomaji("jouhouki")
        let action = handler.buildCandidateList(trigger: .whileTyping)

        guard let payload = action.showPayload else {
            XCTFail("candidates should be shown: \(action)"); return
        }
        XCTAssertEqual(
            payload.candidates[0], "情報共有",
            "5m 以上で unknown prefix 履歴が row 0: \(payload.candidates)"
        )
    }

    // MARK: - 日時候補

    func testKyouIncludesDateCandidates() {
        typeRomaji("kyou")
        let (_, action) = press(keyCode: 49)
        guard let payload = action.showPayload else {
            XCTFail(".show を返すはず: \(action)"); return
        }
        XCTAssertTrue(payload.candidates.contains { $0.contains("-") }, "ISO日付が候補に含まれるはず: \(payload.candidates)")
        XCTAssertTrue(payload.candidates.contains { $0.hasSuffix("日") }, "日本語日付が候補に含まれるはず")
    }
}
