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

## S-03: Successor モードの 1 打目（入力起動）

**前提**: `東京` を確定済み（`successorEligible = true`）または `leftSideContext` が `"今日は東京に"` 等。noun-bigram `(東京, が)` を学習済み。

| ステップ | キー | 動作 |
|---------|------|------|
| 0 | — | 確定直後は候補ウィンドウを出さない |
| 1 | `g` | `trySuccessorCandidates("g")` → 候補「が」を `.show` |
| 2a | Space | 先頭候補「が」を確定 |
| 2b | `z` | `g` を通常組成に流す → `gz` の pending から通常組成 |

*Tests: `Core/Sources/CoreTests/InputHandlerSuccessorTests.swift`*

---

## S-03a: Successor 長い後続語（prefix 展開なし）

**前提**: `東京` 確定後、保留に `会議に出席する`（noun-bigram）。1 打目 `k` で読みフィルタを通過。

| ステップ | キー | candidates（例） | 動作 |
|---------|------|------------------|------|
| 1 | `k` | `会議に出席する` | DB 再クエリ + pending merge の結果をそのまま表示（助詞境界 prefix 展開は行わない） |

*Tests: `Tests/ScenarioRegressionTests.swift`（`testSuccessorPrefixSplit_longBigramOnFirstKey`）*

---

## S-03b: Successor モードの後続語予測（noun-bigram）

**前提**: `東京`（漢字末尾）を確定。事前に noun-bigram `(prev=東京, について, について)` を学習済み。`lastConfirmedNounOutput = 東京`。

| ステップ | キー | 状態 | candidates | 動作 |
|---------|------|------|-----------|------|
| 0 | — | Successor モード | 保存（`pendingSuccessorCandidates`） | noun-bigram あり → 確定直後は `.dismiss`（ウィンドウは開かない） |
| 1a | `n`（「に」「の」行） | Successor モード | `["について", "に", "の", ...]` | 1打目 `romajiToInitialKana["n"]`→「な」行フィルタで一致候補を表示 |
| 1b | Space | 待機 | — | 1打後、先頭候補を確定 |
| 1c | マッチしないキー | 待機 | — | 一致候補なし → モード解除→通常入力 |

`isNounLike` が偽（ひらがな末尾）なら noun-bigram があっても Successor モードには入らない。  
名詞末尾で noun-bigram が空でも isNounLike なら Successor モードに入る。1 打目で `fetchHistoryPrefix` が履歴から候補を補完する。

*Tests: `Tests/InputHandlerSuccessorTests.swift`*

---

## S-03d: Successor 履歴前方一致（noun-bigram 空）

**前提**: 「東京タワー」を複数回確定すると `recordPrefixes` により `たわー` → `タワー` 等の前方一致エントリが履歴に蓄積される。noun-bigram `(東京, タワー)` は未学習。

| ステップ | キー | 状態 | candidates | 動作 |
|---------|------|------|-----------|------|
| 0 | — | Successor モード | 保存（空） | noun-bigram なし → 確定直後は `.dismiss` |
| 1 | `t` | Successor モード | `["タワー", ...]` | 1打目 `fetchHistoryPrefix("た")` で履歴から「タワー」を表示 |
| 2 | Enter | 待機 | — | 「タワー」確定 |

*Tests: sandbox 回帰（`seed_history input=たわー output=タワー` + `toukyou` Space Enter → `t`）*

---

## S-03c: Successor チェーン（名詞→格助詞確定後）

**前提**: `東京` を確定。noun-bigram `(東京, が)` を学習済み。

| ステップ | キー | 状態 | 動作 |
|---------|------|------|------|
| 0 | — | Successor モード | noun-bigram あり（`が` が学習済み）→ `.dismiss`（確定直後はウィンドウなし） |
| 1 | `g` | Successor モード | `pendingSuccessorCandidates` を読みフィルタして表示（`["が", ...]`）|
| 2 | Space | 待機 | 「が」確定 → ひらがな末尾（`isNounLike` 偽）→ `successorEligible` を立てず Successor 終了 |

**変更点（旧仕様との差異）**: 以前は「が」確定後も `suggestSuccessors()` が再呼び出しされ、`(が, 好き)` など N-gram があればチェーンが継続していた。現在はひらがな末尾確定後は Successor に入らないため、格助詞の後は通常の組成に戻る。

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

## S-05: 予測候補の表示（noun-bigram）

**前提**: `lastCommittedOutput = "東京"`、`lastConfirmedNounOutput = "東京"` とする。

**入力**: `ni` (「に」組成中)

- `noun_bigram` を `lastConfirmedNounOutput × 読み` で検索（例: prev=`東京`, reading=`に*`）
- ヒット例: `に` → 候補: `に` / `は` / `の`
- 候補リスト優先順位: ひらがな・カタカナ固定 → ユーザー辞書 →（Zenzai ON かつ左文脈ありなら）**辞書先頭 1 行** → **予測（noun-bigram）** → 履歴 → 残りの辞書

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

**句読点（`,`/`.`）**: 組成なし・非 ASCII モードで `,`/`.` を入力すると Bracket モードに入り、`、`/`。` 等の候補が表示される（`bracketOptions`）。

**Shift+句読点**: Shift を押しながら `,`/`.` を入力すると `characters` が `<`/`>` となり Bracket モードに入り、`＜`/`＞` 等の候補が表示される。

| 入力 | Shift | 出力 |
|------|-------|------|
| `,` | なし | Bracket モード → `、` 等 |
| `.` | なし | Bracket モード → `。` 等 |
| `,` | あり | Bracket モード → `＜` 等 |
| `.` | あり | Bracket モード → `＞` 等 |
| `-` | なし | `ー` |

*Tests: `Tests/InputHandlerPunctuationTests.swift`*

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
- `を` 確定（助詞）→ noun-bigram は記録されない（助詞は `lastConfirmedNounOutput` を更新しない）
- `行く` 確定 → POS 分類で名詞と判定 → noun-bigram `(prev="今日", input=読み, output="行く")` を記録 → `lastConfirmedNounOutput = "行く"`

**次回**: `を` の直後に `い` を打つと、`lastConfirmedNounOutput == "今日"` により noun-bigram `(今日, い*, ...)` から `行く` が予測候補の先頭付近に追加される。

**制約**: 文頭の最初の名詞は `prevNoun == nil` のため noun-bigram は記録されない。Apple Intelligence 無効時は noun-bigram は蓄積・参照されない。

*Tests: `Tests/NounBigramTests.swift`*

---

## S-11: セグメント手動境界調整

**1回目の入力**: `kyouha` Space

| ステップ | キー | 状態 | セグメント | 動作 |
|---------|------|------|-----------|------|
| 1 | Space | セグメントモード | AzooKey 初期分割（例: `きょう`+`は`） | `segmentize` + 必要なら `tryManualBisection` |
| 2 | Shift+← | セグメントモード | 境界縮小 → `isManuallyAdjusted = true` | フォーカス文節を1文字縮小 |
| 3 | Enter | 待機 | — | 手動調整あり → `recordPrefixes` 二重記録（history ブースト） |

**2回目の入力**: `kyouha` Space → AzooKey 初期分割に戻る（境界は DB に保存しない）。

*Tests: `Tests/InputHandlerSegmentTests.swift`*

---

## S-12: 日時候補の選択

**前提**: `lastCommittedOutput` は空（文頭）。

| ステップ | キー | 状態 | markedText | 動作 |
|---------|------|------|-----------|------|
| 1 | `k`,`y`,`o`,`u` | 組成中 | `きょう` | ローマ字変換 |
| 2 | Space | 候補選択中 | `今日`（選択中） | `buildCandidateList` が候補を組み立て。リスト末尾側（historyEnd 直後）に `2026年4月29日` / `4月29日` / `2026-04-29` / `2026/04/29` を追加 |
| 3 | ↓×N | 候補選択中 | `2026-04-29` | 日時候補まで移動 |
| 4 | Enter | 待機 | — | `2026-04-29` を確定。`recordPrefixes` には**記録しない**（数字・日時確定） |

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
