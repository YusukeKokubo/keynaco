# PLAN260502 — ゴーストテキスト推測変換（llama.cpp / Qwen3 FIM 連携）

作成日: 2026-05-02

---

## 概要

ローカルで稼働する llama.cpp HTTP サーバー（Qwen3 FIM モデル）と連携し、
日本語入力中にカーソル右側へ「ゴーストテキスト（灰色の予測文字列）」を
オーバーレイ表示する機能を追加する。

- **Tab** キーでゴーストテキストを確定挿入
- 入力停止 400ms でリクエスト発火（debounce）
- 次のキー入力で進行中のリクエストを即時キャンセル

---

## アーキテクチャ方針

### 既存コードとの責務分担

| コンポーネント | 役割 | 変更要否 |
|---|---|---|
| `InputHandler` (struct) | 純粋入力ロジック・状態管理 | **変更なし** |
| `InputController` (@MainActor class) | IMK ブリッジ・イベント振り分け | **変更あり**（統合層） |
| `CandidateWindow` | 既存の候補ウィンドウ | **変更なし** |
| `TextInputClient` プロトコル | テキスト操作抽象 | **変更あり**（周辺テキスト取得追加） |
| `GhostTextEngine` (new) | debounce・HTTP・Task 管理 | 新規作成 |
| `GhostTextWindow` (new) | ゴーストテキスト描画 NSPanel | 新規作成 |

非同期処理（Task, Timer）はすべて `GhostTextEngine` に閉じ込める。
`InputHandler` は値型のまま変更しない。

---

## 実装ステップ

### Step 1 — `TextInputClient` に `surroundingText` を追加

**ファイル**: `Sources/TextInputClient.swift`

FIM プロンプト生成のためにカーソル周辺テキストを取得できるようにする。

```swift
// プロトコルに追加
func surroundingText(maxLength: Int) -> (prefix: String, suffix: String)

// extension でデフォルト実装（テストの MockTextClient はそのまま使える）
extension TextInputClient {
    func surroundingText(maxLength: Int = 200) -> (prefix: String, suffix: String) {
        return ("", "")
    }
}
```

**ファイル**: `Sources/InputController.swift` 内の `IMKTextInputAdapter`

```swift
func surroundingText(maxLength: Int = 200) -> (prefix: String, suffix: String) {
    guard let c = client else { return ("", "") }
    let sel = c.selectedRange()
    guard sel.location != NSNotFound else { return ("", "") }
    let prefixStart = max(0, sel.location - maxLength)
    let prefix = c.string(
        from: NSRange(location: prefixStart, length: sel.location - prefixStart),
        actualRange: nil
    ) ?? ""
    let suffix = c.string(
        from: NSRange(location: sel.location + sel.length, length: maxLength),
        actualRange: nil
    ) ?? ""
    return (prefix, suffix)
}
```

> IMKTextInput は `string(from:actualRange:)` を持つ。
> `sel.location + sel.length` は marked text を除いたカーソル位置。

---

### Step 2 — `GhostTextWindow` を新規作成

**ファイル**: `Sources/GhostTextWindow.swift`

`CandidateWindow` と同じ `.popUpMenu` レベルの borderless NSPanel。
ゴーストテキストを薄いグレーの `NSTextField` で表示する。

```
┌─────────────────────────────────┐
│  [既存組成テキスト] [予測テキスト灰色]  ← カーソル行の右に floating
└─────────────────────────────────┘
```

設計仕様:
- `styleMask: [.borderless, .nonactivatingPanel]` + `level: .popUpMenu`
- `backgroundColor: .clear`, `isOpaque: false`, `hasShadow: false`
- ラベルフォント: `.systemFont(ofSize: 15)`, textColor: `.tertiaryLabelColor`
- 位置: カーソル矩形 `rect` の右端に揃える（`rect.maxX, rect.midY`）
  - 画面右端はみ出し時は折り返して下の行に表示
- 公開 API:
  - `func show(text: String, near cursorRect: NSRect)`
  - `func dismiss()`
  - `var currentText: String? { get }`

```swift
@MainActor
final class GhostTextWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private(set) var currentText: String?

    // ... init, setupViews, show, dismiss
}
```

---

### Step 3 — `GhostTextEngine` を新規作成

**ファイル**: `Sources/GhostTextEngine.swift`

debounce タイマー・URLSession Task・ゴーストテキスト状態をすべて管理する。
`@MainActor` クラスにすることで `InputController` から安全に呼べる。

```swift
@MainActor
final class GhostTextEngine {

    // MARK: - 設定（将来は UserDefaults / 設定画面に移せる）
    static let endpointURL = URL(string: "http://localhost:8080/completion")!
    static let debounceInterval: TimeInterval = 0.4

    private var debounceTimer: Timer?
    private var currentTask: Task<Void, Never>?
    private let ghostWindow: GhostTextWindow

    var hasGhostText: Bool { ghostWindow.currentText != nil }

    init(ghostWindow: GhostTextWindow) {
        self.ghostWindow = ghostWindow
    }

    // MARK: - 公開 API

    /// キー入力後に呼ぶ。既存 timer/task をリセットして 400ms 後に発火。
    func schedule(prefix: String, suffix: String, near rect: NSRect) {
        cancelInternal()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: Self.debounceInterval, repeats: false) { [weak self] _ in
            self?.fire(prefix: prefix, suffix: suffix, near: rect)
        }
    }

    /// キー入力（Tab 確定以外）で呼ぶ。timer/task/表示をすべてキャンセル。
    func cancel() {
        cancelInternal()
        ghostWindow.dismiss()
    }

    /// Tab 確定時に呼ぶ。true を返したら consumed = true にする。
    func confirm(into client: TextInputClient) -> Bool {
        guard let text = ghostWindow.currentText else { return false }
        cancelInternal()
        ghostWindow.dismiss()
        client.insertText(text)
        return true
    }

    // MARK: - Private

    private func cancelInternal() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        currentTask?.cancel()
        currentTask = nil
    }

    private func fire(prefix: String, suffix: String, near rect: NSRect) {
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await Self.fetchCompletion(prefix: prefix, suffix: suffix)
                guard !Task.isCancelled, !text.isEmpty else { return }
                await MainActor.run {
                    self.ghostWindow.show(text: text, near: rect)
                }
            } catch {
                // サーバー未起動・タイムアウト等は静かに無視
            }
        }
    }

    // MARK: - HTTP リクエスト（Qwen3 FIM 仕様）

    private static func fetchCompletion(prefix: String, suffix: String) async throws -> String {
        let prompt = "<|fim_prefix|>\(prefix)<|fim_suffix|>\(suffix)<|fim_middle|>"
        let payload: [String: Any] = [
            "prompt":      prompt,
            "n_predict":   30,
            "temperature": 0.1,
            "stop":        ["\n", "<|endoftext|>", "<|file_separator|>"]
        ]
        var request = URLRequest(url: endpointURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return "" }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? String else { return "" }
        return content.trimmingCharacters(in: .whitespaces)
    }
}
```

---

### Step 4 — `InputController` に統合

**ファイル**: `Sources/InputController.swift`

#### 4-1. プロパティ追加

```swift
private static let ghostWindow: GhostTextWindow = GhostTextWindow(...)
private lazy var ghostTextEngine = GhostTextEngine(ghostWindow: Self.ghostWindow)
```

`CandidateWindow` と同様にクラスレベルのシングルトンにする
（複数 `InputController` インスタンスが同時に存在しても1つのウィンドウを共有）。

#### 4-2. `handle(_ event:)` に追記

既存の `handler.handle()` 呼び出しの**前**に Tab 確定判定を挿入し、
**後**にゴーストテキストのスケジュールを追加する。

```swift
override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    // ... 既存の flagsChanged/capsLock 処理 ...
    guard event.type == .keyDown else { return false }

    let adapter = IMKTextInputAdapter(sender)

    // --- Ghost text: Tab で確定、その他のキーはキャンセル ---
    if event.keyCode == KeyCode.tab && ghostTextEngine.hasGhostText {
        // successor / bracket モード中はゴーストテキストより既存動作を優先しない
        // （isSuccessorMode / isBracketMode 中は ghost はそもそも表示されない設計）
        return ghostTextEngine.confirm(into: adapter)
    }
    ghostTextEngine.cancel()  // Tab 以外の全キーでキャンセル
    // --------------------------------------------------------

    // ... 既存の EventViewer デバッグ処理 ...

    let ctx = CandidateContext(...)
    let (consumed, action) = handler.handle(...)

    // ... 既存の switch action { ... } 処理 ...

    // --- Ghost text: 組成中で特定モードでない場合に debounce スケジュール ---
    scheduleGhostTextIfNeeded(adapter: adapter)
    // -----------------------------------------------------------------------

    return consumed
}

private func scheduleGhostTextIfNeeded(adapter: IMKTextInputAdapter) {
    // ゴーストテキストを発火しない条件
    guard !InputHandler.isAsciiMode,
          !handler.isSuccessorMode,
          !handler.isBracketMode,
          !handler.state.isSegmentMode,
          !candidateWindow.isVisible,
          !handler.state.composingText.isEmpty
    else { return }

    let (prefix, suffix) = adapter.surroundingText()
    let fullPrefix = prefix + handler.state.composingText
    ghostTextEngine.schedule(prefix: fullPrefix, suffix: suffix, near: adapter.cursorRect())
}
```

#### 4-3. `activateServer` にキャンセルを追加

```swift
override func activateServer(_ sender: Any!) {
    super.activateServer(sender)
    ghostTextEngine.cancel()   // ← 追加
    // ... 既存処理 ...
}
```

#### 4-4. `commitComposition` にキャンセルを追加

```swift
override func commitComposition(_ sender: Any!) {
    ghostTextEngine.cancel()   // ← 追加
    // ... 既存処理 ...
}
```

---

## ファイル変更サマリー

| ファイル | 変更内容 |
|---|---|
| `Sources/TextInputClient.swift` | `surroundingText(maxLength:)` を protocol + extension に追加 |
| `Sources/InputController.swift` | `IMKTextInputAdapter.surroundingText()` 実装、`GhostTextEngine` 統合、Tab ハンドリング |
| `Sources/GhostTextEngine.swift` | **新規**: debounce + HTTP + Task キャンセル管理 |
| `Sources/GhostTextWindow.swift` | **新規**: ゴーストテキスト描画 NSPanel |

---

## Tab キーの競合回避

現在 Tab は以下の箇所で使われている:

| 場所 | 条件 | Tab の動作 |
|---|---|---|
| `handleBracketModeKey` | `isBracketMode == true` | `selectNext` |
| `handleSuccessorMode` | `isSuccessorMode == true` | 既存候補の `selectNext` |
| **ゴーストテキスト（新規）** | `ghostTextEngine.hasGhostText` | `confirm` → 挿入 |

設計上、`isBracketMode` / `isSuccessorMode` が真のときはゴーストテキストをスケジュールしない
（`scheduleGhostTextIfNeeded` の guard で弾く）ので、3条件が同時に真になることはない。

---

## ゴーストテキストウィンドウの位置計算

```
cursorRect = adapter.cursorRect()
// カーソル右端 + 少し右に表示
origin.x = cursorRect.maxX + 2
origin.y = cursorRect.midY - labelHeight / 2

// 画面右端はみ出し → カーソルの下に表示
if origin.x + labelWidth > screen.maxX {
    origin.x = cursorRect.minX
    origin.y = cursorRect.minY - labelHeight - 2
}
```

---

## 非対応・スコープ外

- 設定画面への llama.cpp エンドポイント URL 追加（Step 3 の static let を将来移行）
- サーバー未起動時のユーザー通知（現在は静かに無視）
- ゴーストテキストの部分確定（単語単位で Tab を複数回押す）
- 組成なし（composingText が空）のときの後続予測（Successor モードが既に担当）

---

## 懸念点・リスク

| 懸念 | 対策 |
|---|---|
| `IMKTextInput.string(from:actualRange:)` を実装していないクライアントが返す nil | `?? ""` でフォールバック。prefix/suffix が空でも FIM は動作する |
| llama.cpp レスポンスが遅い（1–3秒）場合の UX | 400ms debounce のため打鍵中は発火しない。表示は非同期なので UI ブロックなし |
| ゴーストテキストが確定後の位置ずれ | confirm 時に `cursorRect()` を再取得せずテキスト挿入のみ行う（ウィンドウはすぐ dismiss） |
| Swift 6 strict concurrency | `GhostTextEngine` を `@MainActor` にすることで Sendable 要件を満たす |
| URLSession と `Task.isCancelled` の競合 | `try await URLSession.shared.data(for:)` は Task キャンセルで `CancellationError` をスロー。`catch` で静かに無視 |

---

## 実装順序（推奨）

1. Step 1（TextInputClient 拡張）→ テストがコンパイルできることを確認
2. Step 2（GhostTextWindow）→ ビルドのみ確認
3. Step 3（GhostTextEngine）→ ビルド確認
4. Step 4（InputController 統合）→ `/deploy` でインストール、手動テスト

手動テスト手順:
- `llama-server -m qwen2.5-coder-0.6b-instruct-q8_0.gguf --port 8080` を起動
- テキストエディタに切り替え、日本語モードでローマ字を入力
- 400ms 待機 → グレーのゴーストテキストが出現することを確認
- Tab キーで確定、別のキーでキャンセルされることを確認
