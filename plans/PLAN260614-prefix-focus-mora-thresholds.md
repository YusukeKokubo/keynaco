---
status: implemented
created: 2026-06-14
related_commit: f226933
---

# PLAN260614: 打鍵中の前方一致補完 — 品詞別モーラ閾値

## 目的

打鍵中（`.whileTyping`）の前方一致履歴・ユーザー辞書 prefix について、**品詞ごとに補完を始める最低モーラ数**を分け、早期の誤補完を減らす。

| 品詞 | 最低モーラ数 |
|------|-------------|
| 名詞・固有名詞 | 2 |
| 動詞 | 3 |
| その他（形容詞・未分類等） | 5 |
| 助詞・助動詞 | 対象外 |

`docs/concept.md` 指針 1「機能語と内容語でサジェスト価値が違う」の延長。名詞は早め、動詞・形容詞は慎重に。

## 背景

### 先行実装

- `805b5a9` — 打鍵中のみ、前方一致履歴の**名詞・固有名詞**（2 モーラ以上）を初期フォーカス
- `PLAN260613` — 候補並びの `lcid` 整備（本件の品詞判定基盤）

### 課題（実装前の議論）

1. **`prefixFocusCandidate` だけが閾値を見る** — フォールバックの `afterFixed` で履歴 row 0 が無条件選択され、AzooKey 未到着時に動詞が 2 モーラでフォーカスされる
2. **`lcid` 欠落** — 非同期 `schedulePOSClassification` 前は `unknown`（5 モーラ必要）扱いになり、4 モーラの名詞が弾かれる
3. **部分読みでの辞書 lookup** — `lcidForCommitted(reading: 組成中読み, …)` が前方一致中に失敗しやすい

## 設計方針

### スコープ

- **対象**: 打鍵中の初期行選択（`InitialRowPolicyResolver`）のみ
- **対象外**: explicit（Space）トリガ — 従来どおり prefix focus 無効
- **読み完全一致履歴** — 閾値なしで最優先維持（ユーザーがその読みで確定した実績を尊重）

### ロジックの置き場所

`InitialRowPolicyResolver` に集約（新ファイルは増やさない）。

1. **`rankForPrefixFocus`** — 品詞ランク解決（1 関数・固定順）
   ```
   lcid（DB）→ pos（DB、NULL 行のみ）→ 履歴最長 input で辞書 lookup → 組成読みで辞書 lookup
   ```
2. **`prefixFocusCandidate`** — 前方一致候補のうち閾値を満たす先頭
3. **`whileTypingInitialRow`** — 閾値未満の前方一致履歴行を初期行から外す。フォーカス可能行がなければ `nil`（候補 UI 非表示）

### 閾値未満で先が無いとき

履歴だけで辞書/カタカナも無い場合は **候補 UI を出さない**（誤フォーカスよりマシ）。カタカナ行へ逃がすケースあり。

### PLAN260613 との関係

ランキング本体は引き続き `lcid` 正本。prefix focus の **`lcid` 欠落時フォールバックに限り** `pos` と最長読み lookup を使う（PLAN260613 の「NULL 行限定 `from(pos:)`」と整合）。

## 実装

### コミット

| commit | 内容 |
|--------|------|
| `4c8ce8a` | 品詞別モーラ閾値の導入（名詞 2 / 動詞 3 / その他 5） |
| `f226933` | 初期行後処理・`rankForPrefixFocus`・`longestInputForOutput` |

### 変更ファイル

| ファイル | 変更 |
|---------|------|
| `Core/Sources/Core/InitialRowPolicyResolver.swift` | 閾値・rank 解決・`whileTypingInitialRow` |
| `Core/Sources/Core/DatabaseManager+History.swift` | `longestInputForOutput` |
| `Core/Sources/Core/InputHandler+Candidates.swift` | 組み込み・dismiss 分岐 |
| `Core/Sources/CoreTests/InitialRowPolicyResolverTests.swift` | 単体テスト |
| `Core/Sources/CoreTests/InputHandlerHistoryTests.swift` | 結合テスト |

## 検証

### ユニットテスト

`./scripts/test_core.sh` — 477 件パス（`f226933` 時点）。

### sandbox（`f226933`、Debug ビルド）

| シナリオ | 結果 |
|---------|------|
| 動詞 `たべ`（2m） | ✓ 履歴「食べる」にフォーカスしない |
| 動詞 `たべる`（3m） | ✓ 「食べる」 |
| 形容詞 `おもしろ`（4m） | ✓ 「面白い」にフォーカスしない |
| 形容詞 `おもしろい`（5m） | ✓ 「面白い」 |
| AzooKey 未到着 + `たべ` | ✓ 「食べる」未選択（`タベ` 等へ） |
| explicit Space | ✓ prefix focus 無効 |
| 名詞 `だけんす` + seed のみ | △ `ダケンス` に負ける（下記） |

手順の注意: 履歴シード後は `type_string` → `wait_azoo_key` → `state` で assert（`wait_azoo_key` だけを test_suite 最終ステップにすると `selectedText` が取れない）。

## 既知の限界

### 名詞・初回（`pos`/`lcid` 未設定）

`sandbox` の `seed_history` は `pos`/`lcid` を付けない。`打鍵数削減` が `unknown` 扱い（5 モーラ必要）になり、4 モーラの `だけんす` では prefix focus が外れ AzooKey 先頭に負ける。

本番では確定後の `schedulePOSClassification` で改善する想定。ユニットテスト `testWhileTyping_prefixHistoryFocusesNounWithPosOnly` で `pos` のみでも動作確認済み。

### 未着手（様子見）

- 確定直後の POS 分類タイミング短縮（非同期のまま初回名詞を安定させるか）
- sandbox `seed_history` への `pos`/`lcid` オプション（テスト再現性向上。本番ロジックとは独立）

## 関連

- 先行: `805b5a9` feat(core): focus prefix-matched nouns on initial row while typing
- 基盤: [PLAN260613-pos-candidate-ranking.md](PLAN260613-pos-candidate-ranking.md)
- 候補パイプライン: [PLAN260612-async-candidate-pipeline.md](PLAN260612-async-candidate-pipeline.md)（`deferAzooKeyWhileTyping` とタイミング相互作用あり）
