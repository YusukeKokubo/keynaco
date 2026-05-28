## 設計案：同音異義語の選び直しネガティブフィードバック

### 問題の整理

ユーザーが「とうきょう」と入力して候補一覧から「東経」を選んで確定（Enter）した後、Backspace で消して「東京」を選び直す。このとき「東経」のスコアをネガティブフィードバックとして下げたい。

現状の動作を追うと：
1. 「東経」を Enter で確定 → `commitText` が呼ばれ `lastConfirmedContext = LastConfirmedContext(input: "とうきょう", output: "東経", ...)` がセットされる
2. Backspace → `doBackspace` → `state.backspace()` は組成中でないため `handled = false`
3. `!handled, let ctx = lastConfirmedContext` が成立 → `db.penalizeAll(input: "とうきょう", output: "東経", ...)` が呼ばれる
4. **`lastConfirmedContext = nil`** に reset される
5. ユーザーが再度「とうきょう」と打ち直し「東京」を選んで確定

**ポイント**: 既に `penalizeAll` でスコアを下げるロジックは存在する。現状の `penalizeAll` は `count - 1` するだけで、「東京」を選び直したという情報は使っていない。

### 現状と今回のギャップ

```
現状: 確定直後 Backspace → penalizeAll で "東経" の count -= 1
                         ↓
問題: 選び直して「東京」を確定するとき、"東経" へのペナルティはそれだけで終わり
      → 「東経」が count=4 あれば count=3 になるが依然上位に残る
```

「東経」が選び直し前に count が少ない（例: count=1）の場合は `penalizeAll` で削除される。しかし count が多い場合は効きが弱い。

### 今回提案する機能

**「訂正選び直しペナルティ」**: 確定後 Backspace → 再入力 → 別の候補を確定という流れを検出したとき、元の誤選択候補を追加でペナルティする。

#### 実装戦略

既に `lastConfirmedContext` と `penalizeAll` の基盤がある。追加で必要なのは「Backspace 後に再入力して別候補を確定した」という検出だけ。

**新フィールド**: `penalizedContext: LastConfirmedContext?`（`penalizeAll` 実行後に保持する）

`doBackspace` で `penalizeAll` が発動したとき、現在は `lastConfirmedContext = nil` で終わる。代わりに `penalizedContext = ctx` として保持しておく。

次に別の候補を確定する `commitText` のタイミングで：
- `penalizedContext` がある
- 今から確定しようとしている output が `penalizedContext.output` と異なる（＝選び直した）
- 読みが同じ（`penalizedContext.input == 新しいinput`）

この3条件が揃ったとき、`penalizedContext.output`（「東経」）に追加ペナルティをかける。

#### DBレイヤーの変更

`penalizeAll` は今のところ `count - 1` + count <= 0 なら削除するシンプルなロジック。「選び直し」は意図的な訂正なので、より強いペナルティが妥当。

選択肢：
1. `count - 2`（追加1回）
2. `count` を 0 に直接セット → 削除
3. 専用の `penalizeReselect(input:rejectedOutput:)` メソッドを追加

**推奨: 選択肢3（専用メソッド）**。理由：ログ・デバッグ・将来の閾値調整が容易。実装は `count` を追加で -1 するのが適切（Backspace 分 -1 + ここで -1 = 合計 -2 相当）。

#### 具体的な実装変更ファイル

**1. `DatabaseManager.swift` に新メソッド追加**

```swift
/// 同音異義語の選び直し（意図的な訂正）を検出したとき、誤選択候補のスコアを追加ペナルティする。
/// `penalizeAll`（Backspace での count-1）に続いて呼ばれる前提。
func penalizeReselect(input: String, rejectedOutput: String) {
    dispatchWrite {
        self.executeOnQueue("BEGIN")
        self.executeOnQueue(
            "UPDATE history SET count = count - 1 WHERE input = ? AND output = ?") {
            self.bindText($0, 1, input); self.bindText($0, 2, rejectedOutput)
        }
        self.executeOnQueue(
            "DELETE FROM history WHERE input = ? AND output = ? AND count <= 0") {
            self.bindText($0, 1, input); self.bindText($0, 2, rejectedOutput)
        }
        self.executeOnQueue("COMMIT")
    }
}
```

**2. `InputHandler.swift` に `penalizedContext` フィールド追加**

```swift
/// Backspace による誤変換訂正（`penalizeAll` 実行済み）の情報。
/// 次の確定で別の候補を選んだとき追加ペナルティするために保持する。
/// 不変条件: commitText で発動後または doEscape で nil にリセットする。
public var penalizedContext: LastConfirmedContext? = nil
```

**3. `doBackspace` 内で `penalizedContext` を保存**

```swift
if !handled, let ctx = lastConfirmedContext {
    db.penalizeAll(input: ctx.input, output: ctx.output, fullReading: ctx.fullReading)
    penalizedContext = ctx   // ← 追加
    lastConfirmedContext = nil
}
```

**4. `commitText` 内で選び直し検出 → `penalizeReselect` 呼び出し**

```swift
// 選び直しネガティブフィードバック
if let pctx = penalizedContext,
   pctx.input == state.finalizedText,   // 同じ読み
   text != pctx.output {                // 別の候補を選んだ
    db.penalizeReselect(input: pctx.input, rejectedOutput: pctx.output)
}
penalizedContext = nil
```

**5. `doEscape` でも `penalizedContext` を nil に**

```swift
public mutating func doEscape(...) {
    penalizedContext = nil
    ...
}
```

#### 重要な設計判断：再入力過程でのリセットをしない

`clearLastConfirmedContextUnlessBackspace` では `penalizedContext` を触らない（`lastConfirmedContext` だけリセット）。理由：「とうきょう」を再入力する過程でローマ字キー（t, o, u, k...）が来るたびにリセットされると機能しなくなるため。

`commitText` の input 一致チェック（`pctx.input == state.finalizedText`）が誤適用を防ぐ安全弁として機能する。

#### 「東経」を何度も選び直した場合の収束

- count が少ない場合（例: count=1）: Backspace 直後に `penalizeAll` で count=0 → 削除。以降の候補リストに出ない
- count が多い場合（例: count=5）: Backspace で count=4、選び直しで `penalizeReselect` → count=3。繰り返すごとに減少

### まとめ

| ファイル | 変更内容 |
|---|---|
| `Core/Sources/Core/DatabaseManager.swift` | `penalizeReselect(input:rejectedOutput:)` メソッド追加 |
| `Core/Sources/Core/InputHandler.swift` | `penalizedContext: LastConfirmedContext?` フィールド追加、`doBackspace` で保存、`commitText` で発動・nil化、`doEscape` で nil化 |

**注意点**：
- `penalizedContext` は Backspace 以外の一般キー入力ではリセットしない（再入力過程でリセットされてしまうため）
- `commitText` の input 一致チェックが誤適用を防ぐ安全弁
- 既存 `penalizeAll` と組み合わさるので実質 count -= 2 相当になる（初回確定が count=1 なら Backspace 直後に削除）
- 実装前にテストを書く（`InputHandlerHistoryTests` に「選び直し → rejectedOutput が追加ペナルティされる」ケースを追加）
- セグメントモード（`doConfirmSegments`）は当面対象外とする（複数文節の複合確定で検出が複雑なため）
