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

## S-03: Successor モードの 1 打目バッファリング（格助詞 fast-path）

**前提**: `東京` を確定した直後（末尾カタカナ → `isNounLike` 真 → bi-gram 候補 + 格助詞 fallback を表示）

| ステップ | キー | successorFirstChar | 動作 |
|---------|------|--------------------|------|
| 1 | `g` | `g` | バッファリング。`particleRomajiMap["g"] = ["が"]` で候補を「が」に絞り込み |
| 2a | `a` | — | `が` を確定 → bigram があれば Successor 継続、なければ待機 |
| 2b | `z` | — | `g` を通常入力として流す（`g` → pendingRomaji）、モード解除 |

2b のケースでは、1 打目 `g` が組成バッファに入り直し、`gz` の途中状態から通常の組成処理が続く。
**注意**: この fast-path は `isNounLike(last)` を満たすとき限定。ひらがな末尾の語の後は 1 打目で即座に通常組成へフォールスルーする。

*Tests: `Tests/InputHandlerSuccessorTests.swift`*

---

## S-03b: Successor モードの後続語予測（trigram + bigram）

**前提**: `おつかれ`（ひらがな末尾）を確定。事前に bigram `(おつかれ, です, です)` を学習済み。  
さらに 2 語前に `今日` を確定済みなら trigram `(今日, おつかれ, *, さまです)` があれば trigram が優先される。

| ステップ | キー | 状態 | candidates | 動作 |
|---------|------|------|-----------|------|
| 0a | — | Successor モード | `["さまです", "です"]` | trigram あり → trigram 優先、bigram で補完 |
| 0b | — | Successor モード | `["です"]` | trigram なし → bigram のみ。格助詞 fallback なし（`isNounLike` 偽） |
| 1a | Space | 待機 | — | 先頭候補を確定 |
| 1b | `k` | 組成中 | — | fast-path 非該当 → 通常組成、`k` が pendingRomaji へ |

trigram も bigram も空で `isNounLike` も偽なら、確定直後に `.dismiss` が返り Successor モードには入らない。

*Tests: `Tests/InputHandlerSuccessorTests.swift`*

---

## S-03c: Successor チェーン（格助詞を経由した連鎖）

**前提**: `東京` を確定。bigram `(東京, が)` および `(が, 好き)` を学習済み。

| ステップ | キー | 状態 | 動作 |
|---------|------|------|------|
| 0 | — | Successor モード | candidates: `["が", ...]`（bigram + 格助詞 fallback）|
| 1 | Space | Successor モード | 「が」確定 → `suggestSuccessors()` → candidates: `["好き"]` |
| 2 | Space | 待機 | 「好き」確定 → bigram なし → `.dismiss` |

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
- 候補リスト優先順位: ひらがな・カタカナ固定 → **予測（trigram + bigram）** → 履歴 → 辞書

*Tests: `Tests/InputHandlerSuccessorTests.swift`*

---

## S-06: Shift+Delete で履歴削除

**状態**: 候補選択中、履歴セクションの候補（index < `historyEnd`）を選択中

- Shift+Delete → `DatabaseManager` から該当エントリを削除
- 候補ウィンドウをリフレッシュ（削除した候補が消える）

**制約**: 辞書候補（`index >= historyEnd`）に対しては無効。

*Tests: `Tests/InputHandlerCandidatesTests.swift`*

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
