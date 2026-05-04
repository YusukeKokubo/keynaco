# デバッグ強化: 内部状態スナップショット付き常時記録ログ

## 動機

現在の `EventViewerWindow` は「どのキーが押されて action ラベルが何だったか」しか記録しない。
不可解な挙動（候補が期待通りに出ない、Successor モードに入らない／抜けない等）を事後に
再現・報告するには以下の情報が必要だが、今はどこにも残らない。

- `composedHiragana` / `pendingRomaji` / `isSegmentMode` などの組成状態
- `isSuccessorMode` / `isBracketMode` / `isAsciiMode` のモードフラグ
- `setMarkedText` に渡した実テキスト
- `candidateContext`（isVisible、selectedRow、selectedText）
- `committedHistory`（直近の確定語列）
- 任意タイミングでの内部ログメッセージ（デバッグ print の代替）

また現状は EventViewer ウィンドウが**開いているときのみ**記録するため、
気づいたときにはすでに消えていることがほとんど。

---

## 設計概要

### 新コンポーネント: `DebugEventLog`

常時動作するリングバッファ（`Sources/Debug/DebugEventLog.swift`）。
EventViewer の開閉とは独立して動き、直近 500 エントリを保持する。

```
DebugEntry
├── id: Int           (単調増加カウンタ)
├── timestamp: String
├── kind: Kind
│   ├── .keyEvent(keyCode, chars, baseChars, mods, bundleID)
│   ├── .result(consumed, action, markedText)
│   ├── .stateSnapshot(InputHandlerSnapshot)
│   └── .log(tag, message)          // 任意のデバッグメッセージ
└── （将来: .llmCall / .llmResult）
```

```
InputHandlerSnapshot
├── composedHiragana: String
├── pendingRomaji: String
├── isSegmentMode: Bool
├── isAsciiMode: Bool
├── isSuccessorMode: Bool
├── isBracketMode: Bool
├── committedHistory: [String]     // suffix(5)
├── candidateVisible: Bool
├── selectedRow: Int
├── selectedText: String?
└── candidates: [String]           // prefix(20)
```

### EventViewer の変更

- 録画ゲートを `isVisible` から削除（常時記録）
- 行選択時に **ボトムペイン**（Detail View）で `InputHandlerSnapshot` を全表示
- エントリ種別（keyEvent / result / stateSnapshot / log）をアイコンで区別
- 「バグ報告」ボタン追加: リングバッファ全体を JSONL にダンプ → Finder で開く

### `InputController` 側の変更

各キーイベント処理の前後で `DebugEventLog.shared` を呼ぶ。

```
handle(event:client:)
  1. DebugEventLog.shared.addKeyEvent(...)
  2. let result = inputHandler.handle(...)
  3. DebugEventLog.shared.addResult(consumed, action, markedText)
  4. DebugEventLog.shared.addStateSnapshot(inputHandler.snapshot())
```

`InputHandler` に `snapshot() -> InputHandlerSnapshot` メソッドを追加。
`@MainActor` の `InputController` から呼ぶだけなので並行性の問題なし。

### 任意ログ API

```swift
// InputHandler 内部から呼べる軽量ログ
DebugEventLog.shared.log(tag: "successor", "threshold not met: count=\(count)")
```

`DEBUG` ビルドのみコンパイルする（`#if DEBUG` ブロック）。
Release では空関数にして実行時コスト ≒ 0。

---

## ファイル変更一覧

| ファイル | 変更内容 |
|---------|---------|
| `Sources/Debug/DebugEventLog.swift` | **新規**: リングバッファ、`InputHandlerSnapshot`、`DebugEntry` |
| `Sources/Debug/EventViewerWindow.swift` | 常時記録化、Detail ペイン追加、バグ報告ボタン、`DebugEventLog` を参照 |
| `Sources/InputHandler.swift` | `snapshot() -> InputHandlerSnapshot` メソッド追加 |
| `Sources/InputController.swift` | `handle(event:client:)` 内に `DebugEventLog.shared` 呼び出しを3点追加 |

新規ファイルは1ファイルのみ。既存ファイルへの変更は局所的。

---

## Detail ペインのレイアウト

EventViewer ウィンドウを NSSplitView で上下に分割。

```
┌──────────────────────────────────────────────────────┐
│ [クリア] [一時停止]          [バグ報告] [コピー] [JSONL] │
├──────────────────────────────────────────────────────┤
│ 時刻   | kc | chars | mods | consumed | action | app │  ← 上ペイン（既存テーブル）
│ ...                                                  │
├──────────────────────────────────────────────────────┤
│ composedHiragana: "かんじ"                             │  ← 下ペイン（Detail View）
│ pendingRomaji:    ""                                  │    選択行の InputHandlerSnapshot
│ isSuccessorMode:  false                               │    または .log の message
│ committedHistory: ["今日", "は"]                      │
│ candidates[0..4]: ["漢字", "感じ", "幹事", ...]       │
└──────────────────────────────────────────────────────┘
```

Detail ペインは `NSTextView`（monospace、読み取り専用）で表示する。
行選択のたびに `DebugEventLog` から当該 id のエントリを検索して整形して流す。

---

## 実装順序

1. `DebugEventLog.swift` を新規作成（`InputHandlerSnapshot` + `DebugEntry` + リングバッファ）
2. `InputHandler.snapshot()` を追加
3. `InputController` に3点の呼び出しを追加
4. `EventViewerWindow` をリファクタ: 録画ゲート除去 → `DebugEventLog.shared` から読む形に
5. NSSplitView で Detail ペインを追加
6. 「バグ報告」ボタン実装（JSONL ダンプ）
7. 任意ログ API（`DebugEventLog.shared.log`）を `InputHandler+SuccessorMode.swift` などに試験投入

---

## 未採用の案

| 案 | 不採用理由 |
|----|-----------|
| os_log / Console.app への出力 | 別アプリを開かないと確認できない。リアルタイム性が低い |
| クラッシュレポート形式 | 常時 overhead が大きい。keynaco は開発者自身が動かす |
| LLM 呼び出しの詳細ログ | 本 PLAN のスコープ外（Phase 2 で追加可能） |
