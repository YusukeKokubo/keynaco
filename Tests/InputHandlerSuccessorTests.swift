import XCTest
@testable import keynaco

// See: docs/domain/states.md#successor-モード
// See: docs/domain/glossary.md#issuccessormode
// See: docs/domain/scenarios.md#s-03-successor-モードの-1-打目バッファリング格助詞-fast-path

final class InputHandlerSuccessorTests: InputHandlerTestCase {

    // MARK: - Successor モード（確定後の後続語予測 / 格助詞クイック選択を含む）
    // See: docs/domain/states.md#successor-モード
    // See: docs/domain/scenarios.md#s-03-successor-モードの-1-打目バッファリング格助詞-fast-path

    func testSuccessorModeActivatesAfterCommit() {
        typeRomaji("tokyo")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode, "漢字確定後はSuccessor モードになるはず")
        guard case .show(let candidates, _, _, _, _) = result.candidateAction else {
            XCTFail("格助詞リストを表示するはず: \(result.candidateAction)"); return
        }
        XCTAssertTrue(InputHandler.particles.allSatisfy { candidates.contains($0) }, "全格助詞が候補に含まれるはず")
    }

    func testSuccessorModeSpaceConfirmsParticle() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        // Space で先頭の格助詞を確定
        let firstParticle = InputHandler.particles[0]  // "が"
        let result = press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: firstParticle)
        XCTAssertTrue(result.consumed)
        XCTAssertFalse(handler.isSuccessorMode, "確定後はSuccessor モードを抜けるはず")
        XCTAssertTrue(client.inserted.contains(firstParticle), "格助詞が挿入されるはず")
    }

    func testSuccessorModeEscapeDismisses() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        let result = press(keyCode: 53)  // Escape
        XCTAssertTrue(result.consumed)
        XCTAssertFalse(handler.isSuccessorMode)
        guard case .dismiss = result.candidateAction else {
            XCTFail("Escape は .dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorModeRomajiExitsAndComposesNormally() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        // "s" は格助詞マッチなし → Successor モード解除して通常組成
        let result = type(chars: "s", base: "s")
        XCTAssertFalse(handler.isSuccessorMode, "マッチなしキーでSuccessor モードを抜けるはず")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "s", "通常の組成が始まるはず")
    }

    func testSuccessorModeNotRetriggeredWithoutBigramData() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let firstParticle = InputHandler.particles[0]
        press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: firstParticle)
        // bigram 学習ゼロ → 格助詞確定後も Successor 候補が空で再起動しない
        XCTAssertFalse(handler.isSuccessorMode, "bigram なし → Successor モードにならないはず")
    }

    func testSuccessorChain() {
        // bigram 事前学習: 東京→が, が→好き（読み: すき）
        handler.db.recordBigram(prev: "東京", input: "が", output: "が")
        handler.db.recordBigram(prev: "が", input: "すき", output: "好き")

        // "東京" 確定 → Successor モード（N-gram あり → .dismiss）
        typeRomaji("tokyo")
        let commitResult = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        guard case .dismiss = commitResult.candidateAction else {
            XCTFail(".dismiss を返すはず（N-gram 候補あり）: \(commitResult.candidateAction)"); return
        }

        // "g" → 格助詞 fast-path（名詞末尾）で「が」を表示
        let showResult = type(chars: "g", base: "g")
        guard case .show(let shown, _, _, _, _) = showResult.candidateAction else {
            XCTFail(".show を返すはず: \(showResult.candidateAction)"); return
        }
        XCTAssertTrue(shown.contains("が"), "bigram 学習済みの「が」が候補に含まれるはず")

        // "が" 確定 → 次の Successor 候補（好き）が出る
        let chain1 = press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertTrue(client.inserted.contains("が"))
        XCTAssertTrue(handler.isSuccessorMode, "が確定後も Successor モードが継続するはず")
        // 「が」→「好き」は bigram あり → .dismiss（1打目まで遅延）
        guard case .dismiss = chain1.candidateAction else {
            XCTFail(".dismiss を返すはず（N-gram 候補あり）: \(chain1.candidateAction)"); return
        }

        // "s" → 「す」行フィルタで「好き」（読み: すき）を表示
        let showResult2 = type(chars: "s", base: "s")
        guard case .show(let cands1, _, _, _, _) = showResult2.candidateAction else {
            XCTFail(".show を返すはず: \(showResult2.candidateAction)"); return
        }
        XCTAssertTrue(cands1.contains("好き"), "bigram 学習済みの「好き」が候補に含まれるはず")

        // "好き" 確定 → bigram なし → Successor モード終了
        let chain2 = press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "好き")
        XCTAssertTrue(client.inserted.contains("好き"))
        XCTAssertFalse(handler.isSuccessorMode, "好き確定後は Successor モードが終了するはず")
        guard case .dismiss = chain2.candidateAction else {
            XCTFail(".dismiss を返すはず: \(chain2.candidateAction)"); return
        }
    }

    func testSuccessorModeArrowNavigates() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        let result = press(keyCode: 125, candidateVisible: true, selectedRow: 0, selectedText: "が")  // ↓
        guard case .selectNext = result.candidateAction else {
            XCTFail("↓ は .selectNext を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorModeRomajiUniqueFiltersAndConfirmWithSpace() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        // "g" → が（唯一マッチ）→ フィルタリング表示（まだ確定しない）
        let filterResult = type(chars: "g", base: "g")
        XCTAssertTrue(filterResult.consumed)
        XCTAssertTrue(handler.isSuccessorMode, "フィルタリング中はSuccessor モードを維持するはず")
        guard case .show(let candidates, _, _, _, _) = filterResult.candidateAction else {
            XCTFail("絞り込み後は .show を返すはず: \(filterResult.candidateAction)"); return
        }
        XCTAssertEqual(candidates, ["が"], "「が」のみが候補に含まれるはず")
        // Space で確定
        let confirmResult = press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertFalse(handler.isSuccessorMode, "確定後はSuccessor モードを抜けるはず")
        XCTAssertTrue(client.inserted.contains("が"), "「が」が挿入されるはず")
        guard case .dismiss = confirmResult.candidateAction else {
            XCTFail("確定後は .dismiss を返すはず: \(confirmResult.candidateAction)"); return
        }
    }

    func testSuccessorModeRomajiAmbiguousFilters() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        // "n" → に・の（複数マッチ）→ 絞り込み表示
        let result = type(chars: "n", base: "n", candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertTrue(result.consumed)
        XCTAssertTrue(handler.isSuccessorMode, "絞り込み中はSuccessor モードを維持するはず")
        guard case .show(let candidates, _, _, _, _) = result.candidateAction else {
            XCTFail("絞り込み後は .show を返すはず: \(result.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("に") && candidates.contains("の"), "に・の が候補に含まれるはず: \(candidates)")
        XCTAssertFalse(candidates.contains("が"), "他の格助詞は含まれないはず")
    }

    func testSuccessorModeUnmatchedKeyExitsMode() {
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        // "a" → 格助詞マッチなし → Successor モード解除して通常入力
        let result = type(chars: "a", base: "a")
        XCTAssertFalse(handler.isSuccessorMode, "マッチなしキーでSuccessor モードを抜けるはず")
        XCTAssertEqual(client.markedText, "あ", "通常の組成になるはず")
    }

    // MARK: - Successor モード：格助詞 fallback の発火条件（名詞末尾のみ）
    // See: docs/domain/glossary.md#issuccessormode
    // See: docs/domain/scenarios.md#s-03b-successor-モードの後続語予測trigram--bigram

    func testSuccessorModeActivatesAfterKanji() {
        typeRomaji("tokyo")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode, "漢字末尾の確定後は格助詞モードになるはず")
        guard case .show = result.candidateAction else {
            XCTFail(".show を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorModeActivatesAfterKatakana() {
        typeRomaji("koohii")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "コーヒー")
        XCTAssertTrue(handler.isSuccessorMode, "カタカナ末尾の確定後は格助詞モードになるはず")
        guard case .show = result.candidateAction else {
            XCTFail(".show を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorModeNotActivatedAfterHiragana() {
        typeRomaji("ta")  // → "た"（ひらがな確定）
        let result = press(keyCode: 36)
        XCTAssertFalse(handler.isSuccessorMode, "ひらがな末尾の確定後は格助詞モードにならないはず")
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorModeNotActivatedAfterSymbol() {
        typeRomaji("a")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "？")
        XCTAssertFalse(handler.isSuccessorMode, "記号確定後は格助詞モードにならないはず")
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorModeNotActivatedAfterASCII() {
        typeRomaji("a")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "Hello")
        XCTAssertFalse(handler.isSuccessorMode, "ASCII確定後は格助詞モードにならないはず")
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    func testSuccessorModeNotActivatedAfterJapanesePunctuation() {
        typeRomaji("a")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "！")
        XCTAssertFalse(handler.isSuccessorMode, "日本語感嘆符確定後は格助詞モードにならないはず")
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    // MARK: - Successor モード：bi-gram 一般化
    // See: docs/domain/scenarios.md#s-03b-successor-モードの後続語予測trigram--bigram
    // See: docs/domain/scenarios.md#s-03c-successor-チェーン格助詞を経由した連鎖

    func testSuccessorModeShowsBigramTopAfterHiraganaCommit() {
        // 事前に「おつかれ → です」を学習させる
        handler.db.recordBigram(prev: "おつかれ", input: "です", output: "です")
        typeRomaji("otsukare")
        let commitResult = press(keyCode: 36)  // Enter でひらがな確定
        XCTAssertTrue(handler.isSuccessorMode, "ひらがな末尾でも bi-gram があれば Successor モードになる")
        // N-gram 候補あり → 確定直後は .dismiss（ウィンドウ閉じて1打目待ち）
        guard case .dismiss = commitResult.candidateAction else {
            XCTFail(".none を返すはず: \(commitResult.candidateAction)"); return
        }
        XCTAssertFalse(handler.pendingSuccessorCandidates.isEmpty, "pendingSuccessorCandidates に候補が保存されているはず")
        // 任意の1打 → N-gram 候補を表示
        let showResult = type(chars: "d", base: "d")
        guard case .show(let candidates, _, _, _, _) = showResult.candidateAction else {
            XCTFail("1打後は .show を返すはず: \(showResult.candidateAction)"); return
        }
        XCTAssertEqual(candidates, ["です"], "bi-gram 学習済みの output のみ表示（格助詞 fallback なし）")
    }

    func testSuccessorModeBigramOrderedByFrequency() {
        // 「東京 → さいきん（最近）」を 3 回、「東京 → さらに」を 1 回 学習（同じさ行で頻度順を検証）
        for _ in 0..<3 { handler.db.recordBigram(prev: "東京", input: "さいきん", output: "最近") }
        handler.db.recordBigram(prev: "東京", input: "さらに", output: "さらに")
        typeRomaji("tokyo")
        let commitResult = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        // N-gram 候補あり → 確定直後は .dismiss（ウィンドウ閉じて1打目待ち）
        guard case .dismiss = commitResult.candidateAction else {
            XCTFail(".dismiss を返すはず: \(commitResult.candidateAction)"); return
        }
        // "s" → さ行フィルタ → 頻度順で表示
        let showResult = type(chars: "s", base: "s")
        guard case .show(let candidates, _, _, _, _) = showResult.candidateAction else {
            XCTFail("1打後は .show を返すはず: \(showResult.candidateAction)"); return
        }
        let idxSaikin = candidates.firstIndex(of: "最近")
        let idxSarani = candidates.firstIndex(of: "さらに")
        XCTAssertNotNil(idxSaikin, "「最近」が候補に含まれるはず")
        XCTAssertNotNil(idxSarani, "「さらに」が候補に含まれるはず")
        if let i = idxSaikin, let s = idxSarani {
            XCTAssertLessThan(i, s, "頻度の高い bi-gram 候補が先頭")
        }
    }

    func testSuccessorFirstCharFallthroughOnSecondKeyMismatch() {
        // S-03 2b: 格助詞1打目 "g" をバッファ後、マッチしない2打目 "z" が来ると
        // "g" を通常入力に流してモード解除し、"gz" が pendingRomaji に入る
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)

        // 1打目 "g" → successorFirstChar にバッファ、候補を "が" に絞り込む
        let filterResult = type(chars: "g", base: "g")
        XCTAssertTrue(handler.isSuccessorMode, "「g」バッファリング中はSuccessor モードを維持")
        XCTAssertNotNil(handler.successorFirstChar, "successorFirstChar にバッファされているはず")
        guard case .show(let filtered, _, _, _, _) = filterResult.candidateAction else {
            XCTFail("絞り込み後は .show を返すはず: \(filterResult.candidateAction)"); return
        }
        XCTAssertEqual(filtered, ["が"], "「g」で候補が「が」のみに絞り込まれるはず")

        // 2打目 "z" → マッチなし → "g" を通常入力に流しモード解除
        let result = type(chars: "z", base: "z")
        XCTAssertFalse(handler.isSuccessorMode, "2打目マッチなしでSuccessor モードを抜けるはず")
        XCTAssertNil(handler.successorFirstChar, "successorFirstChar がクリアされるはず")
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.markedText, "gz", "「g」→「z」が通常組成（pendingRomaji: gz）に入るはず")
    }

    func testSuccessorModeNonParticleBigramShowsOnFirstKey() {
        // ひらがな末尾「おつかれ」の後に非格助詞 bi-gram「です」を学習
        handler.db.recordBigram(prev: "おつかれ", input: "です", output: "です")
        typeRomaji("otsukare")
        let commitResult = press(keyCode: 36)  // 「おつかれ」確定 → Successor モードへ（.dismiss）
        XCTAssertTrue(handler.isSuccessorMode)
        guard case .dismiss = commitResult.candidateAction else {
            XCTFail(".dismiss を返すはず（N-gram 候補あり）: \(commitResult.candidateAction)"); return
        }
        // 「d」打鍵 → 格助詞 fast-path 非該当（非名詞末尾）→ で行フィルタで「です」を表示
        let showResult = type(chars: "d", base: "d")
        XCTAssertTrue(handler.isSuccessorMode, "pendingSuccessorCandidates 表示中は Successor モード継続")
        guard case .show(let candidates, _, _, _, _) = showResult.candidateAction else {
            XCTFail(".show を返すはず（N-gram 候補）: \(showResult.candidateAction)"); return
        }
        XCTAssertEqual(candidates, ["です"], "bi-gram 学習済みの「です」が表示されるはず")
    }

    func testSuccessorModeParticleFallbackOnlyWhenNounLike() {
        // 学習なしの状態で「た」（ひらがな末尾）を確定
        typeRomaji("ta")
        let result = press(keyCode: 36)
        XCTAssertFalse(handler.isSuccessorMode, "ひらがな末尾 + 学習なしなら Successor モードは起動しない")
        guard case .dismiss = result.candidateAction else {
            XCTFail(".dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    // MARK: - Trigram 統合テスト
    // See: docs/domain/glossary.md#prev2output
    // See: docs/domain/scenarios.md#s-05-予測候補の表示trigram--bigram

    func testSuccessorChainViaParticleFastPath() {
        // S-03c: 格助詞 fast-path ("g" で絞り込み → Space で確定) を経由した Successor チェーン
        // testSuccessorChain は Space 直接確定のみ検証。本テストは絞り込み後の確定＋チェーン継続を検証する。
        handler.db.recordBigram(prev: "東京", input: "が", output: "が")
        handler.db.recordBigram(prev: "が", input: "すき", output: "好き")

        typeRomaji("tokyo")
        let commitResult = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        // N-gram 候補あり → 確定直後は .dismiss（ウィンドウ閉じて1打目待ち）
        guard case .dismiss = commitResult.candidateAction else {
            XCTFail(".dismiss を返すはず（N-gram 候補あり）: \(commitResult.candidateAction)"); return
        }

        // "g" → 格助詞 fast-path が発動（名詞末尾 + particleRomajiMap["g"] = ["が"]）
        // pendingSuccessorCandidates は格助詞 fast-path に先に入るので無視される
        let gResult = type(chars: "g", base: "g")
        XCTAssertTrue(handler.isSuccessorMode, "絞り込み中は Successor モードを維持するはず")
        guard case .show(let filtered, _, _, _, _) = gResult.candidateAction else {
            XCTFail(".show を返すはず: \(gResult.candidateAction)"); return
        }
        XCTAssertEqual(filtered, ["が"], "「g」で候補が「が」のみに絞り込まれるはず")

        // Space で「が」確定 → bigram から「好き」あり → N-gram 候補 → .none（1打目まで遅延）
        let spaceResult = press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertTrue(client.inserted.contains("が"), "fast-path + Space で「が」が挿入されるはず")
        XCTAssertTrue(handler.isSuccessorMode, "「が」確定後も Successor モードが継続するはず")
        guard case .dismiss = spaceResult.candidateAction else {
            XCTFail(".dismiss を返すはず（N-gram 候補あり）: \(spaceResult.candidateAction)"); return
        }

        // "s" → す行フィルタで「好き」（読み: すき）を表示
        let chainShowResult = type(chars: "s", base: "s")
        guard case .show(let chain, _, _, _, _) = chainShowResult.candidateAction else {
            XCTFail(".show を返すはず: \(chainShowResult.candidateAction)"); return
        }
        XCTAssertTrue(chain.contains("好き"), "bigram 学習済みの「好き」が後続候補に含まれるはず")

        // Space で「好き」確定 → bigram なし → Successor 終了
        let endResult = press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "好き")
        XCTAssertTrue(client.inserted.contains("好き"))
        XCTAssertFalse(handler.isSuccessorMode, "「好き」確定後は Successor モードが終了するはず")
        guard case .dismiss = endResult.candidateAction else {
            XCTFail(".dismiss を返すはず: \(endResult.candidateAction)"); return
        }
    }

    func testTrigramLearnedAndPrioritizedOverBigram() {
        // 1語目「昨日」確定
        typeRomaji("kinou")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "昨日")
        // Successor モード終了
        press(keyCode: 53) // Escape

        // 2語目「東京」確定
        typeRomaji("toukyou")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        press(keyCode: 53)

        // 3語目「行った」確定（bigram: 東京→行った、trigram: 昨日/東京→行った が学習される）
        typeRomaji("itta")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "行った")
        press(keyCode: 53)

        // bigram のみの競合語「住んだ」を bigram で学習（東京→住んだ）
        // 別文脈: 「今日」「東京」「住んだ」で bigram(東京→住んだ) だけ積む
        let db = handler.db
        db.recordBigram(prev: "東京", input: "すんだ", output: "住んだ")
        db.recordBigram(prev: "東京", input: "すんだ", output: "住んだ")
        db.recordBigram(prev: "東京", input: "すんだ", output: "住んだ")

        // 「昨日」「東京」に続く4語目を組成中 → trigram (昨日/東京→行った) が上に来るはず
        typeRomaji("i")
        let action = type(chars: "t", base: "t")
        guard case .show(let candidates, _, _, _, _) = action.candidateAction else {
            XCTFail("候補が表示されるはず"); return
        }
        // bigram のみ持つ「住んだ」より trigram で学習済みの「行った」が上位にあること
        let idxItta = candidates.firstIndex(of: "行った")
        let idxSunda = candidates.firstIndex(of: "住んだ")
        if let i = idxItta, let s = idxSunda {
            XCTAssertLessThan(i, s, "trigram 由来の候補が bigram のみの候補より上に並ぶ")
        } else if idxItta == nil {
            XCTFail("行った が候補に含まれていない: \(candidates)")
        }
    }

    // MARK: - 即時表示（高信頼チェック）

    func testSuccessorImmediateThresholdNotMet() {
        // count = 4（閾値 5 未満）→ 確定後 .dismiss（遅延表示）
        for _ in 0..<4 {
            handler.db.recordBigram(prev: "東京", input: "について", output: "について")
        }
        typeRomaji("tokyo")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        guard case .dismiss = result.candidateAction else {
            XCTFail("count < threshold → .dismiss を返すはず: \(result.candidateAction)"); return
        }
        XCTAssertFalse(handler.pendingSuccessorCandidates.isEmpty, "保留候補が保存されているはず")
    }

    func testSuccessorImmediateThresholdMet() {
        // count = 5（閾値以上）→ 確定後すぐ .show（即時表示）
        for _ in 0..<5 {
            handler.db.recordBigram(prev: "東京", input: "について", output: "について")
        }
        typeRomaji("tokyo")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        guard case .show(let candidates, _, _, _, _) = result.candidateAction else {
            XCTFail("count >= threshold → .show を返すはず: \(result.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("について"), "高信頼候補「について」が含まれるはず")
        XCTAssertTrue(handler.pendingSuccessorCandidates.isEmpty, "即時表示時は保留候補が空のはず")
    }

    func testSuccessorImmediateThresholdOutdated() {
        // 91日前にcount=5分記録 → 直近90日外なので .dismiss（遅延表示）
        let base: Int64 = 1_700_000_000
        let ninetyOneDaysAgo = base - 91 * 86400
        handler.db.clock = { ninetyOneDaysAgo }
        for _ in 0..<5 {
            handler.db.recordBigram(prev: "東京", input: "について", output: "について")
        }
        handler.db.clock = { base }
        typeRomaji("tokyo")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)
        guard case .dismiss = result.candidateAction else {
            XCTFail("90日超のレコードは閾値対象外 → .dismiss を返すはず: \(result.candidateAction)"); return
        }
    }

    // MARK: - particleRomajiMap の複数候補（n → に/の）

    func testSuccessorModeNKeyShowsBothNiAndNo() {
        // n → particleRomajiMap["n"] = ["に", "の"]、両方 bigram があれば両方表示
        handler.db.recordBigram(prev: "東京", input: "に", output: "に")
        handler.db.recordBigram(prev: "東京", input: "の", output: "の")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)

        let result = type(chars: "n", base: "n")
        guard case .show(let candidates, _, _, _, _) = result.candidateAction else {
            XCTFail("n → .show を返すはず（に/の bigram あり）: \(result.candidateAction)"); return
        }
        XCTAssertTrue(candidates.contains("に"), "「に」が候補に含まれるはず: \(candidates)")
        XCTAssertTrue(candidates.contains("の"), "「の」が候補に含まれるはず: \(candidates)")
        XCTAssertFalse(candidates.contains("が"), "「が」は含まれないはず")
    }

    func testSuccessorModeNKeyKanaArrayOrderPreserved() {
        // N-gram フィルタ経由（pendingSuccessorCandidates あり）の場合、
        // romajiToInitialKana["n"] = ["な","に","ぬ","ね","の"] の kana 配列順で並ぶ。
        // bigram 頻度（の=3 > に=1）ではなく kana 配列順が優先される。
        for _ in 0..<3 { handler.db.recordBigram(prev: "東京", input: "の", output: "の") }
        handler.db.recordBigram(prev: "東京", input: "に", output: "に")
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        let result = type(chars: "n", base: "n")
        guard case .show(let candidates, _, _, _, _) = result.candidateAction else {
            XCTFail(".show を返すはず"); return
        }
        let idxNi = candidates.firstIndex(of: "に")
        let idxNo = candidates.firstIndex(of: "の")
        XCTAssertNotNil(idxNi, "「に」が候補に含まれるはず: \(candidates)")
        XCTAssertNotNil(idxNo, "「の」が候補に含まれるはず: \(candidates)")
        if let ni = idxNi, let n = idxNo {
            XCTAssertLessThan(ni, n, "kana 配列順（に が の より前）で表示されるはず")
        }
    }

    // MARK: - F3: pending と DB の読み前方一致 merge（LLM 追記前提）

    func testMergePendingSuccessorMatchesAppendsHiraganaWhenDbHasMatches() {
        let db = ["資料"]
        let pending = ["しりょう", "きかく"]
        let merged = InputHandler.mergePendingSuccessorMatches(dbOrdered: db, pending: pending, romajiKey: "k")
        XCTAssertEqual(merged.first, "資料", "DB 由来を先に保つ")
        XCTAssertTrue(merged.contains("きかく"), "か行にマッチする保留語が末尾に追加される")
        XCTAssertFalse(merged.contains("しりょう"), "さ行の保留語は k 打鍵では除外")
    }

    func testMergePendingSuccessorMatchesShowsPendingWhenDbEmpty() {
        let merged = InputHandler.mergePendingSuccessorMatches(
            dbOrdered: [], pending: ["しりょう", "えいご"], romajiKey: "s"
        )
        XCTAssertEqual(merged, ["しりょう"], "DB が空でも保留から読み一致する語だけ表示")
    }
}
