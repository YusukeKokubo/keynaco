# keynaco シナリオ集

具体的な入力トレースで状態遷移・ドメインルールを補完する。

---

## S-01: 基本的なローマ字変換

**入力**: `k` `a` `n` `j` `i` Space Enter

| ステップ | キー | 状態 | composedHiragana | pendingRomaji | markedText | 候補ウィンドウ |
|---------|------|------|-----------------|---------------|------------|--------------|
| 0 | — | 待機 | — | — | — | 非表示 |
| 1 | `k` | 組成中 | `` | `k` | `k` | — |
| 2 | `a` | 組成中 | `か` | `` | `か` | 履歴ヒットがあれば表示 |
| 3 | `n` | 組成中 | `か` | `n` | `かn` | — |
| 4 | `j` | 組成中 | `かん` | `j` | `かんj` | — |
| 5 | `i` | 組成中 | `かんじ` | `` | `かんじ` | — |
| 6 | Space | セグメントモード | — | — | `漢字`（AzooKey 先頭） | 表示 |
| 7 | Enter | 待機 | — | — | — | 非表示 → Successor モードへ（末尾が漢字のため） |

**確定後**: `漢字` が挿入される。末尾が漢字（`isNounLike` 真）なので Successor モードへ自動遷移。

*Tests: `Tests/InputHandlerCompositionTests.swift`*

---

## S-01b: nn 直後の Space（hidden pending n）

**入力**: `n` `n` Space

- `nn` のあと: 表示は「ん」、`composedHiragana` は「ん」、内部は pending `n` と `hiddenPendingN` が立つ（`finalizedText` は「ん」のみ）。
- Space: `absorbPendingIntoComposed()` で pending を捨て、**`composedHiragana` を「んん」に増やさない**（Enter 確定と同じ意味）。短い読みでセグメント分割できない場合は通常の候補表示へ。

*Tests: `Core/Sources/CoreTests/InputHandlerHiddenPendingNTests.swift`*

---

## S-02: 候補選択（↑↓）と右矢印確定

**入力**: `k` `a` ↓ ↓ →

| ステップ | キー | 状態 | isExplicitlySelected | 候補ウィンドウ |
|---------|------|------|----------------------|--------------|
| 1–2 | `ka` | 組成中 | false | autoShow で表示（履歴あり時） |
| 3 | ↓ | 候補選択中 | **true** | 1番目を選択 |
| 4 | ↓ | 候補選択中 | true | 2番目を選択 |
| 5 | → | 待機 | — | 非表示 |

→ キーは `commitComposition` を呼び、選択候補を無視して組成テキスト（ひらがな）をそのまま `insertText` で確定する。Enter（選択候補を確定）とは異なる。

*Tests: `Tests/InputHandlerCandidatesTests.swift`*

---

## S-03: Successor モードの 1 打目（保留 + 読み／格助詞マージ）

**前提**: `東京` を確定した直後（末尾カタカナ → `isNounLike` 真 → bi-gram 候補 + 格助詞 fallback を **`pendingSuccessorCandidates` に保存し `.dismiss`**）

| ステップ | キー | successorFirstChar | 動作 |
|---------|------|--------------------|------|
| 0 | — | — | 確定直後はウィンドウを出さず Successor モードのみ |
| 1 | `g` | `g` | `particleRomajiMap["g"]` と DB 併合で候補を「が」に絞り込み |
| 2a | Space | — | 絞り込み中の先頭候補「が」を確定 → bigram があれば Successor 継続、なければ待機 |
| 2b | `z` | — | `g` を通常入力として流す（`g` → pendingRomaji）、モード解除 |

2b のケースでは、1 打目 `g` が組成バッファに入り直し、`gz` の途中状態から通常の組成処理が続く。  
**注意**: `g` の後に `a` を打つと 2b 同様にモード解除→通常組成になり `が` が markedText に入る（自動確定はしない）。
**注意**: 1打目のマージは `pendingSuccessorCandidates` がある場合の経路。ひらがな末尾の語の後は bi-gram があっても Successor には入らない（通常組成へ）。

*Tests: `Tests/InputHandlerSuccessorTests.swift`*

---

## S-03a: Successor 長い後続語の prefix 展開

**前提**: `東京` 確定後、保留に `会議に出席する`（bi-gram または LLM extras）。1 打目 `k` で読みフィルタを通過。

| ステップ | キー | candidates（例） | 動作 |
|---------|------|------------------|------|
| 1 | `k` | `会議`, `会議に`, `会議に出席する` | 助詞境界で体言切り prefix を親の直前に挿入。全体候補は末尾に残す |

*Tests: `Tests/ScenarioRegressionTests.swift`（`testSuccessorPrefixSplit_longBigramOnFirstKey`）、`Tests/InputHandlerSuccessorPrefixTests.swift`*

---

## S-03b: Successor モードの後続語予測（trigram + bigram）

**前提**: `東京`（漢字末尾）を確定。事前に bigram `(東京, について, について)` と trigram `(昨日, 東京, *, 行った)` を学習済み。

| ステップ | キー | 状態 | candidates | 動作 |
|---------|------|------|-----------|------|
| 0a | — | Successor モード | 保存（`pendingSuccessorCandidates`） | trigram あり → 確定直後は `.dismiss`（ウィンドウは開かない） |
| 0b | — | Successor モード | 保存（`pendingSuccessorCandidates`） | trigram なし → bigram のみ + 格助詞 fallback |
| 1a | `n`（「に」「の」行） | Successor モード | `["について", "に", "の", ...]` | 1打目 `romajiToInitialKana["n"]`→「な」行フィルタで一致候補を表示 |
| 1b | Space | 待機 | — | 1打後、先頭候補を確定 |
| 1c | マッチしないキー | 待機 | — | 一致候補なし → モード解除→通常入力 |

`isNounLike` が偽（ひらがな末尾）なら bi-gram / tri-gram があっても Successor モードには入らない。  
名詞末尾で N-gram が空でも、格助詞 fallback は **`pendingSuccessorCandidates` に積まれ**、1打目で表示する。

*Tests: `Tests/InputHandlerSuccessorTests.swift`*

---

## S-03c: Successor チェーン（名詞→格助詞確定後）

**前提**: `東京` を確定。bigram `(東京, が)` を学習済み。

| ステップ | キー | 状態 | 動作 |
|---------|------|------|------|
| 0 | — | Successor モード | N-gram あり（`が` が bigram 学習済み）→ `.dismiss`（確定直後はウィンドウなし） |
| 1 | `g` | Successor モード | `pendingSuccessorCandidates` を読みフィルタして表示（`["が", ...]`）|
| 2 | Space | 待機 | 「が」確定 → ひらがな末尾（`isNounLike` 偽）→ Successor 終了 |

**変更点（旧仕様との差異）**: 以前は「が」確定後も `suggestSuccessors()` が再呼び出しされ、`(が, 好き)` など bigram があればチェーンが継続していた。現在はひらがな末尾確定後は Successor に入らないため、格助詞の後は通常の組成に戻る。

*Tests: `Tests/InputHandlerSuccessorTests.swift`*

---

## S-04: Shift+文字（日本語モードで英字組成）

**入力**: `t` Shift+`O` Shift+`K` `y` `o` Enter

- `t` → pendingRomaji: `t`
- Shift+`O` → `forceFinalize("t")` で pending `t` を先に composedHiragana へ追記し、続けて大文字 `O` を追加（`tO` が蓄積）
- Enter → `tOKyo` 相当の文字列を確定

**ポイント**: 日本語モード中の Shift+ASCII 文字は pendingRomaji 経由ではなく `composedHiragana` に直接追加される。

*Tests: `Tests/InputHandlerAsciiTests.swift`*

---

## S-05: 予測候補の表示（trigram + bigram）

**前提**: `lastCommittedOutput = "東京"`、`prev2Output = "行った"` とする。

**入力**: `ni` (「に」組成中)

- まず `trigram` テーブルを `(行った, 東京) × に*` で検索 → ヒットがあれば優先
- 次に `bigram` テーブルを `東京 × に*` で検索して trigram にない候補を補完
- ヒット例（bigram のみ）: `に` → 候補: `に` / `は` / `の`（東京の後によく続く助詞）
- 候補リスト優先順位: ひらがな・カタカナ固定 → ユーザー辞書 →（Zenzai ON かつ左文脈ありなら）**辞書先頭 1 行** → **予測（trigram + bigram）** → 履歴 → 残りの辞書

*Tests: `Tests/InputHandlerSuccessorTests.swift`*

---

## S-06: Shift+Delete で履歴削除

**状態**: 候補選択中、履歴セクションの候補（index < `historyEnd`）を選択中

- Shift+Delete → `DatabaseManager` から該当エントリを削除
- 候補ウィンドウをリフレッシュ（削除した候補が消える）

**制約**: 辞書候補（`index >= historyEnd`）に対しては無効。

*Tests: `Tests/InputHandlerCandidatesTests.swift`*

---

## S-08: 長音符・Shift+句読点の入力

**長音符（ハイフン）**: 日本語モードの組成中に `-` を入力すると `ー`（長音符）として composedHiragana に追加される。

**Shift+句読点**: `。`/`、` に変換される通常の句読点とは異なり、Shift を押しながら `,`/`.` を入力すると `<`/`>` がそのまま composedHiragana に追加される。

| 入力 | Shift | 出力 |
|------|-------|------|
| `,` | なし | `、` |
| `.` | なし | `。` |
| `,` | あり | `<` |
| `.` | あり | `>` |
| `-` | なし | `ー` |

`punctuationMap` は `baseCharacters`（素文字）で照合するため、Shift あり時は変換されず素文字がそのまま組成に入る。

*Tests: `Tests/InputHandlerCompositionTests.swift`*

---

## S-09: 文節 Space 確定でフレーズ全体が学習される

**前提**: `きょうはよいてんきです` を入力し Space でセグメントモードへ。
5 セグメント（きょう / は / よい / てんき / です）が分割されたとする。

- Enter でセグメント確定 → 各セグメントが個別に `recordPrefixes` される
- **加えて** 合成読み `きょうはよいてんきです` × 合成出力 `今日は良い天気です` が1エントリとして `recordPrefixes` される
- 次回「きょうは」と打つだけで「今日は良い天気です」が履歴候補に出る

**制約**: 1 セグメントのみ確定の場合は合成エントリは記録しない（`segments.count >= 2` ガード）。

*Tests: `Tests/InputHandlerSegmentTests.swift`*

---

## S-10: noun-bigram 経由で助詞をまたぐ予測

**前提**: `今日 → を → 行く` の順で確定済み。`今日` と `行く` が LLM 品詞分類で名詞と判定されている。

- `今日` 確定 → POS 分類完了後 `lastConfirmedNounOutput = "今日"`
- `を` 確定（助詞）→ bigram `(今日, を, を)` のみ記録（格助詞 prev の bigram はスキップ）
- `行く` 確定 → POS 分類で名詞と判定 → noun-bigram `(prev="今日", input=読み, output="行く")` を記録 → `lastConfirmedNounOutput = "行く"`

**次回**: `を` の直後に `い` を打つと、通常 bigram には `(を → い*)` のみだが、
`lastConfirmedNounOutput == "今日"` により noun-bigram `(今日, い*, ...)` から `行く` が予測候補の先頭付近に追加される。

**制約**: 文頭の最初の名詞は `prevNoun == nil` のため noun-bigram は記録されない。Apple Intelligence 無効時は noun-bigram は蓄積されず bigram のみがフォールバック。

*Tests: `Tests/NounBigramTests.swift`*

---

## S-03d: pendingRomaji 先読み予測（1打削減）

**前提**: `東京` を確定。bigram `(東京, について, について)` を学習済み（Successor の閾値未満で遅延表示中）。

| ステップ | キー | 状態 | pendingRomaji | composedHiragana | 動作 |
|---------|------|------|--------------|-----------------|------|
| 0 | — | Successor モード | — | — | N-gram 遅延表示中（`pendingSuccessorCandidates = ["について"]`） |
| 1 | Escape | 待機 | — | — | Successor モードキャンセル（`lastCommittedOutput = "東京"` は保持） |
| 2 | `n` | 組成中 | `n` | `` | **先読み除外**（`n` は `ん` との曖昧さあり） → `.dismiss` |
| — | `i` | 組成中 | `` | `に` | 「に」が組成 → bigram フィルタで候補表示 |

**先読みが効くケース**: `t` を入力すると `romajiToInitialKana["t"]` → 「た行」全体で先読み → 「て」「と」「た」始まりの bi-gram があれば即座に候補表示 → Space で確定（`i` 打鍵を省略）。

| ステップ | キー | 状態 | 動作 |
|---------|------|------|------|
| 0 | — | 待機 | `lastCommittedOutput = "て"`、bi-gram `(て, から)` 学習済み |
| 1 | `k` | Successor モード | `buildPendingCandidateList("k")` → `["か", "き", ..., "から"]` → `.show`（`pendingRomaji = "k"` は保持） |
| 2 | Space | 待機 | `confirmSuccessor("から")` → 「から」確定（`i` を打たず1打削減） |

**制約**: `composedHiragana` が空のとき限定。2文字目（`sh` 等）は対象外（`pending.count == 1` ガード）。

**補足（誤操作）**: 直前に確定した語がなく `isSuccessorMode` も立っていない状態で、子音 1 文字だけ（例: `k`）のときに Space を押すと、キーはホストへ渡さず `pendingRomaji` を表示したまま維持する（本文にスペース文字は入れない）。**先読み**で `isSuccessorMode` 中に候補文脈と不整合で `selectedText` が得られない Space / Enter は、確定に失敗しても同じ `pendingRomaji` を `composingText` で再表示する。

*Tests: `Tests/InputHandlerPendingPreviewTests.swift`, `Tests/InputHandlerCompositionTests.swift`*

---

## S-11: 境界学習の保存と再現

**前提**: 初回入力。`boundary_pref` テーブルは空。

**1回目の入力**: `kyouha` Space

| ステップ | キー | 状態 | セグメント | 動作 |
|---------|------|------|-----------|------|
| 1 | Space | セグメントモード | AzooKey 初期分割（例: `きょうは` / 1セグメント or `きょう`+`は`） | `fetchBoundaryPref` ミス → AzooKey へフォールバック |
| 2 | Shift+← | セグメントモード | 境界縮小 → `isManuallyAdjusted = true` | フォーカス文節を1文字縮小 |
| 3 | Enter | 待機 | — | `isManuallyAdjusted` あり → `saveBoundaryPref(fullReading: "きょうは", segments: [...])` |

**2回目の入力**: `kyouha` Space

| ステップ | キー | 状態 | セグメント | 動作 |
|---------|------|------|-----------|------|
| 1 | Space | セグメントモード | 保存済み境界 | `fetchBoundaryPref("きょうは")` ヒット → 手動調整後の境界で直接セグメントを構築 |

**制約**:
- 完全一致のみ。`きょうはよいてんきです` の保存は `きょうはてんきです` 入力には適用されない
- AzooKey 初期分割のまま（LLM の多文節再構築もない）で手動調整もなく確定した場合は `boundary_pref` に保存されない

*Tests: `Tests/InputHandlerSegmentTests.swift` — `testBoundaryPrefSavedOnManualAdjust`, `testBoundaryPrefReproducedOnReenter`*

---

## S-11b: セグメント LLM 境界（アライメント成功 / 失敗）

**前提**: `きかいがくしゅうをする` を入力し Space でセグメントモードへ。AzooKey は複数文節に分割済みとする。

**アライメント成功**（辞書・読みが整合し `inferSegmentBoundaries` が非 nil）:

| ステップ | イベント | セグメント表示のイメージ |
|---------|-----------|-------------------------|
| 1 | （突入直後） | AzooKey 初期境界のまま |
| 2 | LLM が `機械学習をする` を返す | 読みが `きかいがくしゅう` / `を` / `する` に対応するよう境界が置き換わり、各文節の先頭候補に LLM トークンが並ぶ |
| 3 | Enter（各行先頭選択のまま） | LLM 全文を 1 回確定 → 待機。多文節再構築済みなら `boundary_pref` に当該読み境界を保存 |

**アライメント失敗**（推論が `nil`）:

| ステップ | イベント | 動作 |
|---------|-----------|------|
| 1 | LLM が返すが読みと整合しない | 先頭文節の候補先頭に全文テキストのみ挿入（境界は AzooKey のまま）。`boundary_pref` には保存しない |

**1 ペアのみ整合**（`inferSegmentBoundaries` が 1 文節に収まる）: `applyLLMBoundaries` は走るが `boundary_pref` には保存しない（多文節再構築ではない）。

*Tests: `Tests/SegmentBoundaryTests.swift`、`Tests/InputHandlerSegmentLLMTests.swift`、`Tests/InputHandlerSegmentTests.swift`（LLM 境界の `boundary_pref` 保存）*

---

## S-12: 日時候補の選択

**前提**: `lastCommittedOutput` は空（文頭）。

| ステップ | キー | 状態 | markedText | 動作 |
|---------|------|------|-----------|------|
| 1 | `k`,`y`,`o`,`u` | 組成中 | `きょう` | ローマ字変換 |
| 2 | Space | 候補選択中 | `今日`（選択中） | `buildCandidateList` が候補を組み立て。リスト末尾側（historyEnd 直後）に `2026年4月29日` / `4月29日` / `2026-04-29` / `2026/04/29` を追加 |
| 3 | ↓×N | 候補選択中 | `2026-04-29` | 日時候補まで移動 |
| 4 | Enter | 待機 | — | `2026-04-29` を確定。`recordPrefixes` / bigram / trigram には**記録しない** |

**制約**:
- 日時候補は `historyEnd` より後（AzooKey 辞書候補と同じゾーン）に挿入されるため Shift+Delete 不可
- 確定しても変換履歴に残らない（再変換時にノイズにならない）

*Tests: `Tests/InputHandlerCandidatesTests.swift` — `testKyouIncludesDateCandidates`*
*Tests: `Tests/InputHandlerDateTimeTests.swift`*

---

## S-07: F キーで即時確定

**状態**: `とうきょう` 組成中

| キー | 出力 | 備考 |
|------|------|------|
| F6 | `とうきょう` | ひらがなのまま確定 |
| F7 | `トウキョウ` | 全角カタカナ |
| F8 | `ﾄｳｷｮｳ` | 半角カタカナ |
| F9 | `ｔｏｕｋｙｏｕ` | ひらがな→ローマ字→全角ASCII（`toZenkakuAscii(hiraganaToRomaji(h))`） |
| F10 | `toukyou` | ひらがな→ローマ字（半角ASCII）（`hiraganaToRomaji(h)`） |

*Tests: `Tests/InputHandlerCompositionTests.swift`*
