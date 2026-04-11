# ローカル動作確認の改善計画

## 目的

変更のたびに「ビルド→sudo→killall→手動確認」の重いサイクルを回さずに済むようにする。

---

## A. ユニットテストの拡充

### 背景

現在テストがあるのは `RomajiConverter`、`DatabaseManager`、`ShiftInput` の 3 つ。
`InputController.handle(_:client:)` に集約されたキーイベント処理ロジック（モード切替、候補操作、Backspace/Escape/Return の挙動、ローマ字蓄積→変換の流れ）はテストされていない。

### A-1. CompositionState の抽出

`InputController` から状態遷移ロジックを純粋な型に切り出す。

```swift
struct CompositionState {
    var composedHiragana: String = ""
    var pendingRomaji: String = ""
    var currentCandidates: [String] = []
    var isAsciiMode: Bool = false

    mutating func addRomaji(_ chars: String) -> (candidateRefreshNeeded: Bool)
    mutating func backspace() -> Bool
    mutating func reset()
    var composingText: String { ... }
}
```

`InputController` は `CompositionState` を持ち、`handle` ではステート操作と IMK 呼び出しを分離する。

### A-2. テストケース追加

`CompositionState` に対して以下をテスト：

- **ローマ字入力の蓄積**: `addRomaji("k")` → pending="k", `addRomaji("a")` → hiragana="か", pending=""
- **Backspace**: ローマ字途中で削除、ひらがな削除
- **Escape**: 全リセット
- **Return（未確定あり）**: composingText を返す
- **ASCII モード切替**: `isAsciiMode` のトグル
- **候補リフレッシュ判定**: ひらがな 2 文字以上で true

### A-3. テスト不可能な領域（手動確認が必要なもの）

以下は IMK ランタイム依存のため、ユニットテストでは検証できない：

- カーソル位置に基づく候補ウィンドウの配置
- アプリケーションへのテキスト挿入（`insertText` / `setMarkedText`）
- 各テキストエディタとの IMK 互換性

---

## B. ~/Library/Input Methods/ の検証 — 不採用

検証済み。`~/Library/Input Methods/` に入れると入力ソースが大量に重複登録される。
`lsregister -kill` も macOS 26 で廃止済みのためクリーンアップも困難。
`/Library/Input Methods/`（sudo 必要）を継続する。

---

## 実施順序

1. ~~**B を先にやる**~~ → 完了・不採用
2. ~~**A-1**: `CompositionState` を抽出するリファクタリング~~ → 完了
3. ~~**A-2**: テストケース追加~~ → 完了（51 テスト全パス）
4. ~~テストが通ることを確認（`xcodebuild test`）~~ → 完了
5. `/deploy` で実機確認 ← 次
