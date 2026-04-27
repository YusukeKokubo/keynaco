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
        guard case .show(let candidates, _, _) = result.candidateAction else {
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
        // bigram 事前学習: 東京→が, が→好き
        handler.db.recordBigram(prev: "東京", input: "が", output: "が")
        handler.db.recordBigram(prev: "が", input: "好き", output: "好き")

        // "東京" 確定 → Successor モード
        typeRomaji("tokyo")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        XCTAssertTrue(handler.isSuccessorMode)

        // "が" 確定 → 次の Successor 候補（好き）が出る
        let chain1 = press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "が")
        XCTAssertTrue(client.inserted.contains("が"))
        XCTAssertTrue(handler.isSuccessorMode, "が確定後も Successor モードが継続するはず")
        guard case .show(let cands1, _, _) = chain1.candidateAction else {
            XCTFail(".show を返すはず: \(chain1.candidateAction)"); return
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
        guard case .show(let candidates, _, _) = filterResult.candidateAction else {
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
        guard case .show(let candidates, _, _) = result.candidateAction else {
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
        let result = press(keyCode: 36)  // Enter でひらがな確定
        XCTAssertTrue(handler.isSuccessorMode, "ひらがな末尾でも bi-gram があれば Successor モードになる")
        guard case .show(let candidates, _, _) = result.candidateAction else {
            XCTFail(".show を返すはず: \(result.candidateAction)"); return
        }
        XCTAssertEqual(candidates, ["です"], "bi-gram 学習済みの output のみ表示（格助詞 fallback なし）")
    }

    func testSuccessorModeBigramOrderedByFrequency() {
        // 「東京 → で」を 3 回、「東京 → に」を 1 回 学習
        for _ in 0..<3 { handler.db.recordBigram(prev: "東京", input: "で", output: "で") }
        handler.db.recordBigram(prev: "東京", input: "に", output: "に")
        typeRomaji("tokyo")
        let result = press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        guard case .show(let candidates, _, _) = result.candidateAction else {
            XCTFail(".show を返すはず: \(result.candidateAction)"); return
        }
        let idxDe = candidates.firstIndex(of: "で")!
        let idxNi = candidates.firstIndex(of: "に")!
        XCTAssertLessThan(idxDe, idxNi, "頻度の高い bi-gram 候補が先頭")
        // 名詞末尾なので格助詞 fallback も tail に並ぶ
        XCTAssertTrue(InputHandler.particles.allSatisfy { candidates.contains($0) }, "格助詞 fallback も表示")
    }

    func testSuccessorModeNonParticleBigramFallsThroughOn1stKey() {
        // ひらがな末尾「おつかれ」の後に非格助詞 bi-gram「です」を学習
        handler.db.recordBigram(prev: "おつかれ", input: "です", output: "です")
        typeRomaji("otsukare")
        press(keyCode: 36)  // 「おつかれ」確定 → Successor モードへ
        XCTAssertTrue(handler.isSuccessorMode)
        // 「k」打鍵 → 名詞末尾ではないので fast-path が効かず、通常組成へ
        let result = type(chars: "k", base: "k")
        XCTAssertFalse(handler.isSuccessorMode, "非名詞末尾で 1 打目は fast-path を使わず通常組成へ")
        XCTAssertEqual(client.markedText, "k", "通常の組成が始まる")
        XCTAssertTrue(result.consumed)
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
        guard case .show(let candidates, _, _) = action.candidateAction else {
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
}
