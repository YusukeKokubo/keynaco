# IME サンドボックスウィンドウ

## 目的

開発時に「テキスト入力しながら IME の内部状態をリアルタイムで見る」専用ウィンドウを用意する。
EventViewerWindow はキーイベントの **事後ログ** に特化しているが、本ウィンドウは
「今この瞬間の内部状態」を縦に並べて可視化し、想定外の挙動をその場で診断できるようにする。

---

## レイアウト

```
┌─────────────────────────────────────────────────────────────────────┐
│  IME Sandbox                                                         │
├────────────────────────────┬────────────────────────────────────────┤
│                            │  【組成】                               │
│  （NSTextView）            │  composedHiragana : かんじ             │
│  ここに普通に日本語を入力  │  pendingRomaji    : i                  │
│  する。IME が通常通り動く  │  composingText    : かんじい            │
│                            │                                        │
│                            │  【モード】                            │
│                            │  isAsciiMode      : false              │
│                            │  isSuccessorMode  : false              │
│                            │  isSegmentMode    : false              │
│                            │  isBracketMode    : false              │
│                            │  isExplicitlySelected : false          │
│                            │                                        │
│                            │  【候補】                              │
│                            │  visible          : true               │
│                            │  selectedRow      : 0                  │
│                            │  selectedText     : 漢字               │
│                            │  historyEnd       : 3                  │
│                            │  fixedEnd         : 1                  │
│                            │  [0] 漢字 ★                           │
│                            │  [1] 感じ                              │
│                            │  [2] 幹事                              │
│                            │  ...                                   │
│                            │                                        │
│                            │  【確定履歴】                          │
│                            │  committedHistory  : [今日, は, 良い]  │
│                            │                                        │
│                            │  【セグメント】（segmentMode 中のみ）  │
│                            │  segments : [かんじ | にゅうりょく]    │
│                            │  focusedIndex : 0                      │
└────────────────────────────┴────────────────────────────────────────┘
```

- 左ペイン: `NSTextView`（通常の入力フィールド。IME がそのまま効く）
- 右ペイン: `NSTextView`（monospace、読み取り専用。状態ダンプを随時更新）
- 分割は `NSSplitView`（比率は 50:50、ユーザーがドラッグで調整可能）

---

## 状態公開の仕組み

### `InputHandlerSnapshot` 構造体

`InputController` がキーイベント処理後に `InputHandler` から取得するスナップショット。
PLAN260504c で設計した同名構造体と共用する（`Sources/Debug/DebugEventLog.swift` に定義予定）。

```swift
struct InputHandlerSnapshot {
    // 組成
    var composedHiragana: String
    var pendingRomaji: String
    var composingText: String        // composedHiragana + pendingRomaji
    var markedText: String           // setMarkedText に実際に渡した文字列

    // モード
    var isAsciiMode: Bool
    var isSuccessorMode: Bool
    var isSegmentMode: Bool
    var isBracketMode: Bool
    var isExplicitlySelected: Bool   // ↑↓で候補を明示選択したか

    // 候補（アクション適用後の candidateWindow から取得）
    var candidateVisible: Bool
    var selectedRow: Int
    var selectedText: String?
    var historyEnd: Int
    var fixedEnd: Int
    var candidates: [String]         // 最大 30 件

    // 確定履歴
    var committedHistory: [String]   // suffix(5)

    // セグメント（isSegmentMode 中のみ意味あり）
    var segmentTexts: [String]
    var focusedSegmentIndex: Int
}
```

`InputHandler` に `func snapshot(markedText: String) -> InputHandlerSnapshot` を追加する（候補・候補ウィンドウ状態は `InputController` 側でアクション適用後に `candidateWindow` から補完する）。

### PLAN260504c との `InputHandlerSnapshot` 一本化方針

- **真実のソース**: `Sources/Debug/DebugEventLog.swift`（PLAN260504c が先行する場合）
- PLAN260504c が未実装なら `IMESandboxWindow.swift` に暫定定義し、c 実装時に `DebugEventLog.swift` へ移動して再エクスポートする
- c の定義は `composingText` / `markedText` / `isExplicitlySelected` / セグメント系が欠けているため、**本プランの定義を最終形とし、c をこちらに合わせる**

### 通知フロー

```
InputController.handle(event:client:)
  1. 既存処理（handle → apply → setMarkedText 等）
  2. #if DEBUG
     // アクション適用後の candidateWindow から候補情報を読む
     let snap = InputHandlerSnapshot(
         // inputHandler から組成・モード・確定履歴
         ...inputHandler.snapshot(markedText: lastMarkedText),
         // candidateWindow からアクション適用後の候補状態
         candidateVisible: candidateWindow.isVisible,
         selectedRow: candidateWindow.selectedRow,
         ...
     )
     NotificationCenter.default.post(
         name: .imeStateDidUpdate,
         object: nil,
         userInfo: ["snapshot": snap],
         // メインキューで受け取る（購読側で DispatchQueue.main 不要にする）
     )
     #endif
```

**同期スコープの制約**: 通知は `keyDown` イベント処理後にのみ送出する。
`flagsChanged`（Caps Lock / ASCII 切替）や候補ウィンドウのマウスクリックなど
`handle(event:client:)` 以外の経路では更新しない（初版の割り切り）。
右ペインに「更新: keyDown のみ」と注記するか、タイムスタンプを表示して古さを示す。

通知送出は `DispatchQueue.main.async` で包み、受信側ウィンドウが確実にメインスレッドで UI 更新できるようにする。

`Notification.Name.imeStateDidUpdate` は `Sources/Debug/IMESandboxWindow.swift` 内に定義し、
`#if DEBUG` ブロックで囲む。リリースビルドには一切漏れない。

---

## ファイル変更一覧

| ファイル | 変更内容 |
|---------|---------|
| `Sources/Debug/IMESandboxWindow.swift` | **新規**: サンドボックスウィンドウ本体 |
| `Sources/InputHandler.swift` | `snapshot(...)` メソッド追加 |
| `Sources/InputController.swift` | `handle(event:client:)` 末尾に通知送出（`#if DEBUG`） |
| `Sources/AppDelegate.swift` | NSStatusItem メニューに「サンドボックス…」項目を追加 |

`InputHandlerSnapshot` は PLAN260504c の `DebugEventLog.swift` と共用するが、
PLAN260504c が未実装の場合は `IMESandboxWindow.swift` 内に暫定定義して進める。

---

## `IMESandboxWindow` の実装メモ

- `isReleasedWhenClosed = false`（EventViewerWindow と同じ）
- `NSSplitView` の `dividerStyle = .thin`
- 通知購読は `addObserver(forName: .imeStateDidUpdate, object: nil, queue: .main)` で受け取り、
  クロージャ内で直接 UI 更新する（`DispatchQueue.main.async` の二重 hop 不要）
- 右ペインのテキスト生成: `formatSnapshot(_ snap: InputHandlerSnapshot) -> String`
  - セクション順: 組成 → モード → 候補 → 確定履歴 → セグメント（省略条件あり）
  - セグメントモード中でない場合はセグメントセクションを省略
  - 候補の選択行には `★` マークを付ける
  - 末尾にタイムスタンプ行（`更新: HH:mm:ss keyDown`）を出して「古さ」を示す
- フォント: `NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)`
- 候補の最大表示件数: 30 件（`candidateWindow` の実リスト長と合わせる）

---

## 実装順序

1. `InputHandler.snapshot(...)` を追加（`Sources/InputHandler.swift`）
2. `Sources/Debug/IMESandboxWindow.swift` を新規作成
   - `NSSplitView` + 左 `NSTextView` + 右 `NSTextView`（モノスペース読み取り専用）
   - `NotificationCenter` 購読 → `formatSnapshot` で右ペイン更新
3. `InputController` に通知送出を追加（`#if DEBUG` ブロック）
4. `AppDelegate` の NSStatusItem メニューに「サンドボックス…」を追加

---

## 未採用の案

| 案 | 不採用理由 |
|----|-----------|
| Combine `@Published` で状態を流す | `InputHandler` は struct、`InputController` は `@MainActor` クラス。Combine の追加依存を避けるため `NotificationCenter` で十分 |
| 右ペインを `NSTableView` にする | ラベルと値のペア表示は monospace テキストで十分。行数が動的に変わりテーブルでは管理が煩雑 |
| EventViewerWindow に統合 | EventViewer はログ閲覧用、サンドボックスはライブ状態表示用と目的が異なる。ウィンドウを分ける |
| テキストエリアに確定ログも表示 | EventViewerWindow と重複する。サンドボックスは「今の状態」に集中する |
