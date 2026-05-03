# 訂正シグナル学習

## 現状と課題

確定直後の Backspace を「誤変換の訂正」として扱う仕組みはすでに部分実装されている。

```
doBackspace() → db.penalizeHistory(input:output:)
```

`penalizeHistory` は `history` テーブルの `count` を -1 してゼロ以下になったら行を削除するだけ。
以下のテーブルは**ペナルティ非対象**のため、誤変換が学習に残り続ける。

| テーブル | 問題 |
|---------|------|
| `bigram` | 誤確定語が prev として記録済みだと、次回も同じ候補が Successor で上位に来る |
| `trigram` | 同上（2語前コンテキスト） |
| `skip_bigram` | 同上（格助詞を挟んだ skip コンテキスト） |
| `boundary_pref` | セグメントモードで誤区切りを確定した場合、次回同じ読みで同じ誤区切りが優先される |

さらに `penalizeHistory` は count を 1 だけ下げるため、
高頻度エントリへのペナルティが弱く効果が出づらい。

---

## 方針

### 1. `lastConfirmedPair` の情報を拡張

現在 `lastConfirmedPair: (input: String, output: String)?` しか保持していない。
Backspace 時に bigram/trigram/skip_bigram の行を特定するために prev 情報も保持する。

```swift
// InputHandler の状態に追加（lastConfirmedPair を置き換え）
var lastConfirmedContext: (
    input: String,       // 読み（state.finalizedText）
    output: String,      // 確定テキスト
    prev1: String?,      // commitText 時の lastCommittedOutput
    prev2: String?,      // commitText 時の prev2Output
    skipPrev: String?,   // skip-bigram を記録した場合の prevContent
    fullReading: String? // セグメントモード確定の場合の全読み
)? = nil
```

`commitText` の中で bigram/trigram を記録する直前に prev1/prev2/skipPrev をキャプチャして
`lastConfirmedContext` にセットする。
セグメントモード由来の確定では呼び出し元（`InputHandler+SegmentMode.swift`）で
`fullReading` も渡す。

### 2. `DatabaseManager.penalizeAll(context:)` を実装

`penalizeHistory` を廃止し、全関連テーブルをトランザクションで一括ペナルティする。

```swift
func penalizeAll(
    input: String, output: String,
    prev1: String?, prev2: String?,
    skipPrev: String?,
    fullReading: String?
)
```

各テーブルの動作：

| テーブル | ペナルティ SQL | 条件 |
|---------|--------------|------|
| `history` | `count - 1`、0 以下で DELETE | 常時 |
| `bigram` | `count - 1`、0 以下で DELETE | `prev1 != nil`、`is_preset = 0` のみ |
| `trigram` | `count - 1`、0 以下で DELETE | `prev2 != nil` |
| `skip_bigram` | `count - 1`、0 以下で DELETE | `skipPrev != nil` |
| `boundary_pref` | DELETE | `fullReading != nil` |

bigram のプリセット行（`is_preset = 1`）はペナルティ対象外。
GC 対象外の設計と整合させる。

### 3. Backspace 検出スコープ

- 組成バッファが空でない Backspace（通常削除）は `handled = true` で early return → ペナルティ発火しない（現行維持）
- ペナルティ発火後は `lastConfirmedContext = nil` にリセット（2回発火しない）
- Backspace 以外のキー入力時点で `lastConfirmedContext = nil`（現行 `lastConfirmedPair` と同じタイミング）

---

## 実装ステップ

### Step 1 — `InputHandler.swift`

1. `lastConfirmedPair` を `lastConfirmedContext` に置き換える
2. `commitText` で bigram 記録直前に prev1/prev2/skipPrev をキャプチャ
3. `doBackspace` で `penalizeHistory` → `db.penalizeAll(context:)` に差し替え

### Step 2 — `InputHandler+SegmentMode.swift`

セグメント全確定パスで `fullReading` を `commitText` / `lastConfirmedContext` に渡す。

### Step 3 — `DatabaseManager.swift`

1. `penalizeHistory` を `penalizeAll` に置き換え
2. bigram / trigram / skip_bigram / boundary_pref のペナルティ SQL を `withTransaction` で追加

### Step 4 — テスト

| テストケース | 確認内容 |
|------------|---------|
| 確定→Backspace→再変換 | 同じ読みで history 候補が出ない |
| 確定→Backspace→Successor | bigram 由来の候補が下がる |
| 確定→別キー→Backspace | `lastConfirmedContext` がクリア済みでペナルティしない |
| 高頻度エントリを2回 Backspace | 1回目でペナルティ、2回目は `lastConfirmedContext = nil` なのでスキップ |
| セグメント確定→Backspace | `boundary_pref` が削除され、次回は新しい区切りを学習できる |

---

## 非対象（スコープ外）

- **連続 Backspace による複数確定の取り消し**: `lastConfirmedContext` は直前1件のみ。効きが弱いと感じたら別途設計する。
- **ペナルティ強度の変更**: 今回は count -1 のまま。効きが弱いと判明したら乗数ペナルティ（`MAX(1, count/3)` 等）を検討する。
- **Successor モード中の誤候補**: Successor 候補確定後の Backspace は `lastConfirmedContext` が有効なため自動でペナルティされる（追加対応不要）。
