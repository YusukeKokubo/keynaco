# PLAN260523: Sandbox 左ペイン 行ベース UI への変更

## 背景・目的

現状の `IMESandboxWindow` 左ペインは単純な `NSTextView` で、入力内容が区別なく蓄積される。  
行単位で入力・ログを管理することで「1行 = 1テストケース」として使いやすくする。

## 設計方針

### 行（Line）の概念

- **1行** = ユーザーが Enter を押すまでの一連の入力セッション
- 組成中に Tab・候補選択などで複数回 `insertText` が呼ばれても、Enter まで同じ行に積み上がる
- Enter 押下時:
  - 組成中 → IME が確定してから改行（既存の Enter 挙動に追随）
  - 組成なし → そのまま新しい行へ

### データ構造

```swift
struct SandboxLine {
    let index: Int
    var committedSegments: [String]   // insertText で確定されたテキストの断片
    var events: [LogEntry]            // この行に紐づくイベントログ
    
    var displayText: String { committedSegments.joined() }
}
```

`LogEntry` に `lineIndex: Int` を追加。

### UI 変更

| 場所 | 変更前 | 変更後 |
|------|--------|--------|
| 左ペイン | `NSTextView`（編集可） | `NSTableView`（行一覧）+ 最下行に「入力中」インジケータ |
| 右ペイン上 | 全イベントログ | **選択行のイベントログ**（デフォルト）|
| 右ペイン上 | - | 「全ログ」トグルで全件表示も可 |

左テーブルの列:
- 行番号（`#1`, `#2`, ...）
- 確定テキスト（`committedSegments.joined()`）
- イベント数バッジ（`events.count`）

### Enter のインターセプト

左ペインを `NSTextView` の代わりに `SandboxInputView`（`NSView` サブクラスまたは `NSTextField` 集合体）として実装し、キーダウンをハンドル。  
または、IME の `insertText` + `imeStateDidUpdate` 通知の組み合わせで「行が確定した」タイミングを検出する。

実装上シンプルなのは: 左ペインを **読み取り専用テーブル**（`NSTableView`）にして、実際のキー入力受付は不可視の `NSTextField`（ファーストレスポンダ）を1つ置く方式。この invisible field が Enter を検知したら新行を追加する。

### AI（ソケット）の変更

- `appendSocketSnapshot(_:inserted:)` → `lineIndex: Int` パラメータ追加
- `exportLog()` → 行単位の構造でエクスポート
  ```json
  [
    { "lineIndex": 0, "displayText": "こんにちは", "events": [...] },
    ...
  ]
  ```
- `get_log` ソケットコマンドに `line` フィルタオプション追加（省略時は全行）

## 実装ステップ

1. **`SandboxLine` struct を追加**（`IMESandboxWindow.swift` 内）
2. **`LogEntry` に `lineIndex` を追加**、既存の `push(_:)` を `push(_:lineIndex:)` に変更
3. **`currentLineIndex` を `IMESandboxWindow` に追加**（`var currentLineIndex: Int = 0`）
4. **左ペイン UI を `NSTableView` に置き換え**（`leftTextView` → `lineTableView`）
5. **不可視フォーカスビュー** (`SandboxFocusView`) を左ペインに重ねて Enter を検知
6. **`insertText` 通知の受信**: `IMKInputController` 側で `insertText` 時に Notification を投げ、sandbox 側で `committedSegments` に追記
7. **右ペインのフィルタリング**: 左テーブル選択行が変わったら右テーブルを reloadData（フィルタ適用）
8. **「全ログ」トグルボタン** を Clear ボタン隣に追加
9. **ソケット API 更新**: `appendSocketSnapshot` / `exportLog` に `lineIndex` 対応を追加
10. **動作確認**: sandbox スキルで E2E テスト

## 変更対象ファイル

- `keynaco/Debug/IMESandboxWindow.swift` （主要変更）
- `keynaco/InputController.swift` （`insertText` 時に新 Notification 投げる）
- `scripts/debug_ime.py` （`get_log` の line フィルタ対応）

## 未検討事項

- 行の削除・編集機能（今回スコープ外）
- 行ごとの「再実行」機能（入力シーケンスを保存しておいて再送）
