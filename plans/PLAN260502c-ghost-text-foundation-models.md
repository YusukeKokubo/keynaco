# PLAN260502c — ゴーストテキスト推測変換（macOS 26 Foundation Models）

作成日: 2026-05-02

---

## 概要

macOS 26 の `FoundationModels` フレームワーク（Apple Intelligence オンデバイスモデル）を使い、
日本語入力中にカーソル右側へゴーストテキストを表示する機能を追加する。
llama-server・XPC Service・モデルファイルは一切不要。

```
[InputController] → GhostTextEngine → LanguageModelSession (on-device)
                                            ↓
                                    GhostTextWindow (NSPanel overlay)
```

---

## 前提条件

| 条件 | 内容 |
|---|---|
| macOS 26 以降 | `FoundationModels` は macOS 26 で導入。プロジェクトのデプロイターゲットを macOS 26 に固定するため `#if canImport(FoundationModels)` ガードは不要 |
| Apple Intelligence 有効 | `SystemLanguageModel.default.availability == .available` が必要 |
| App Sandbox | 変更不要（Foundation Models はサンドボックス対応） |
| Swift 6 | `@MainActor` + `Sendable` で strict concurrency 対応 |

Apple Intelligence が無効の環境では `GhostTextEngine.isAvailable` が `false` になり、
機能全体が静かにスキップされる（IME の通常動作には影響しない）。

---

## アーキテクチャ方針

PLAN260502 と同じコンポーネント分割を踏襲する。
HTTP の代わりに `LanguageModelSession` を使うだけで、統合ロジックは同一。

| コンポーネント | 役割 | 変更要否 |
|---|---|---|
| `InputHandler` | 純粋入力ロジック | **変更なし** |
| `InputController` | IMK ブリッジ | **変更あり**（統合層） |
| `TextInputClient` | テキスト操作抽象 | **変更あり**（`surroundingText` 追加） |
| `GhostTextEngine` (new) | debounce・FM セッション・Task 管理 | 新規作成 |
| `GhostTextWindow` (new) | ゴーストテキスト描画 NSPanel | 新規作成 |

---

## 実装ステップ

### Step 1 — `TextInputClient` に `surroundingText` を追加

**ファイル**: `Sources/TextInputClient.swift`

```swift
// プロトコルに追加
func surroundingText(maxLength: Int) -> (prefix: String, suffix: String)

// extension でデフォルト実装（MockTextClient はこのデフォルトを継承するため変更不要）
extension TextInputClient {
    func surroundingText(maxLength: Int = 200) -> (prefix: String, suffix: String) {
        return ("", "")
    }
}
```

**ファイル**: `Sources/InputController.swift` の `IMKTextInputAdapter`

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

---

### Step 2 — `GhostTextWindow` を新規作成

**ファイル**: `Sources/GhostTextWindow.swift`

PLAN260502 の設計と同一。`CandidateWindow` と同じ `.popUpMenu` レベルの borderless NSPanel。

```swift
@MainActor
final class GhostTextWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private(set) var currentText: String?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary]

        label.font = .systemFont(ofSize: 15)
        label.textColor = .tertiaryLabelColor
        label.backgroundColor = .clear
        label.isBordered = false
        contentView?.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: contentView!.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor, constant: -2),
        ])
    }

    func show(text: String, near cursorRect: NSRect) {
        currentText = text
        label.stringValue = text
        label.sizeToFit()
        let width = label.frame.width + 4
        let height = max(cursorRect.height, 20)
        var origin = NSPoint(x: cursorRect.maxX + 2, y: cursorRect.minY)
        // 画面右端はみ出し → カーソルの下に折り返す
        if let screen = NSScreen.main,
           origin.x + width > screen.visibleFrame.maxX {
            origin.x = cursorRect.minX
            origin.y = cursorRect.minY - height - 2
        }
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        orderFront(nil)
    }

    func dismiss() {
        currentText = nil
        label.stringValue = ""
        orderOut(nil)
    }
}
```

---

### Step 2.5 — FoundationModels API 確認（Step 3 の前に必須）

`FoundationModels` は beta API であり、プランのシグネチャが変更されている可能性がある。
Step 3 のコードを書く前に、空のファイルをプロジェクトに追加してコンパイルを通し、以下を確認する。

```swift
import FoundationModels

// 確認チェックリスト:
// 1. SystemLanguageModel.default.availability の型（enum か Bool か）
// 2. LanguageModelSession() のイニシャライザシグネチャ
// 3. session.respond(to:) の第一引数型（String か Prompt か [Message] か）
// 4. respond(to:) の第2引数ラベル（options: か generationOptions: か）
// 5. GenerationOptions の引数ラベル（maximumResponseTokens / maxTokens / maxNewTokens）
// 6. response.content か response.text かプロパティ名

func apiCheck() async throws {
    if case .available = SystemLanguageModel.default.availability {
        let session = LanguageModelSession()
        let options = GenerationOptions(maximumResponseTokens: 30)
        let response = try await session.respond(to: "テスト", options: options)
        print(response.content)
    }
}
```

確認後、実際のシグネチャに合わせて Step 3 のコードを調整してから実装する。

---

### Step 3 — `GhostTextEngine` を新規作成

**ファイル**: `Sources/GhostTextEngine.swift`

```swift
import FoundationModels

@MainActor
final class GhostTextEngine {

    static let debounceInterval: TimeInterval = 0.4
    // 最大生成トークン数。短いほど高速。日本語は1トークン≒1〜2文字なので30で十分。
    static let maxTokens = 30

    private var debounceTimer: Timer?
    private var currentTask: Task<Void, Never>?
    private let ghostWindow: GhostTextWindow
    private let modelAvailable: Bool

    /// Apple Intelligence が利用不可の場合は false。この場合 schedule/confirm は何もしない。
    var isAvailable: Bool { modelAvailable }
    var hasGhostText: Bool { ghostWindow.currentText != nil }

    init(ghostWindow: GhostTextWindow) {
        self.ghostWindow = ghostWindow
        if case .available = SystemLanguageModel.default.availability {
            self.modelAvailable = true
        } else {
            self.modelAvailable = false
        }
    }

    // MARK: - 公開 API

    func schedule(prefix: String, suffix: String, near rect: NSRect) {
        guard isAvailable else { return }
        cancelInternal()
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.debounceInterval, repeats: false
        ) { [weak self] _ in
            self?.fire(prefix: prefix, suffix: suffix, near: rect)
        }
    }

    func cancel() {
        cancelInternal()
        ghostWindow.dismiss()
    }

    /// Tab 確定時。true を返したら consumed = true にする。
    /// NOTE: InputHandler.commitText() を経由しないため committedHistory / bi-gram / tri-gram が
    /// 更新されない。ゴーストテキスト確定は学習 DB に記録されない初期実装の許容事項。
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
        guard modelAvailable else { return }
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                // リクエストごとに新規セッションを生成する。
                // セッションは会話履歴を蓄積するため、使い回すとノイズが増加する。
                let session = LanguageModelSession()
                let text = try await Self.fetchCompletion(
                    session: session, prefix: prefix, suffix: suffix
                )
                guard !Task.isCancelled, !text.isEmpty else { return }
                self.ghostWindow.show(text: text, near: rect)
            } catch {
                // Apple Intelligence 未起動・キャンセル等は静かに無視
            }
        }
    }

    // MARK: - Foundation Models リクエスト

    private static func fetchCompletion(
        session: LanguageModelSession,
        prefix: String,
        suffix: String
    ) async throws -> String {
        let prompt = buildPrompt(prefix: prefix, suffix: suffix)
        let options = GenerationOptions(maximumResponseTokens: maxTokens)
        let response = try await session.respond(to: prompt, options: options)
        return postProcess(response.content)
    }

    private static func buildPrompt(prefix: String, suffix: String) -> String {
        // maxTokens と合わせて「短く」とだけ伝える（数字の二重管理を避ける）
        // 「日本語で」を明示しないとモデルが英語で返す場合がある
        if suffix.isEmpty {
            return """
            次の日本語テキストの続きを短く予測してください。日本語で返してください。
            予測テキストのみを返してください（説明・改行・引用符は不要）。

            \(prefix)
            """
        } else {
            return """
            次の日本語テキストの[空白]部分に入る適切なテキストを短く予測してください。日本語で返してください。
            予測テキストのみを返してください（説明・改行・引用符は不要）。

            \(prefix)[空白]\(suffix)
            """
        }
    }

    private static func postProcess(_ text: String) -> String {
        (text.components(separatedBy: "\n").first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

---

### Step 4 — `InputController` に統合

**ファイル**: `Sources/InputController.swift`

#### 4-0. `IMKTextInputAdapter.cursorRect()` を修正

既存の実装は `characterIndex: 0`（ドキュメント先頭）固定でカーソル位置が取れていない。
ゴーストテキストはカーソル右隣に出るべき表示なので、この実装と同時に修正する。

```swift
func cursorRect() -> NSRect {
    var rect = NSRect.zero
    let loc = client?.selectedRange().location ?? 0
    let idx = loc == NSNotFound ? 0 : loc
    client?.attributes(forCharacterIndex: idx, lineHeightRectangle: &rect)
    return rect
}
```

> `CandidateWindow` も同じ問題を持つが、候補ウィンドウはカーソル下に出るため
> 左端ずれの影響が相対的に小さい。ゴーストテキストとまとめて直す。

#### 4-1. プロパティ追加

```swift
private static let ghostWindow: GhostTextWindow = GhostTextWindow()
// IMK はアプリ切替のたびに InputController を新規生成するため、
// CandidateWindow と同じ static パターンで単一インスタンスを共有する
private static let _ghostTextEngine: GhostTextEngine = GhostTextEngine(ghostWindow: ghostWindow)
private var ghostTextEngine: GhostTextEngine { Self._ghostTextEngine }
```

#### 4-2. `handle(_ event:)` に追記

```swift
override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    // ... 既存の flagsChanged/capsLock 処理 ...
    guard event.type == .keyDown else { return false }

    let adapter = IMKTextInputAdapter(sender)

    // --- Ghost text: Tab で確定、その他のキーはキャンセル ---
    if event.keyCode == KeyCode.tab && ghostTextEngine.hasGhostText {
        return ghostTextEngine.confirm(into: adapter)
    }
    ghostTextEngine.cancel()
    // --------------------------------------------------------

    // ... 既存の EventViewer / handler.handle() 処理 ...

    // --- Ghost text: 確定（consumed=true）のキーではスケジュールしない ---
    // consumed=true のとき composedHiragana は空になっているが、
    // surroundingText の無駄な IMK 呼び出しを避けるため条件を先に置く
    if !consumed {
        scheduleGhostTextIfNeeded(adapter: adapter)
    }
    // ----------------------------------------------------------------------

    return consumed
}

private func scheduleGhostTextIfNeeded(adapter: IMKTextInputAdapter) {
    // composingText = composedHiragana + pendingRomaji のため、
    // pendingRomaji が混入しないよう composedHiragana だけを使う（例: "きょu" を防ぐ）
    guard ghostTextEngine.isAvailable,
          !InputHandler.isAsciiMode,
          !handler.isSuccessorMode,
          !handler.isBracketMode,
          !handler.state.isSegmentMode,
          !candidateWindow.isVisible,
          !handler.state.composedHiragana.isEmpty
    else { return }

    let (prefix, suffix) = adapter.surroundingText()
    let fullPrefix = prefix + handler.state.composedHiragana
    ghostTextEngine.schedule(prefix: fullPrefix, suffix: suffix, near: adapter.cursorRect())
}
```

#### 4-3. `activateServer` / `commitComposition` にキャンセルを追加

```swift
override func activateServer(_ sender: Any!) {
    super.activateServer(sender)
    ghostTextEngine.cancel()   // ← 追加
    // ... 既存処理 ...
}

override func commitComposition(_ sender: Any!) {
    // super より前に cancel する: super がクライアントに insertText を送る前に
    // ゴーストウィンドウを dismiss し、Task も止める
    ghostTextEngine.cancel()   // ← 追加
    super.commitComposition(sender)
    // ... 既存処理 ...
}
```

---

## ファイル変更サマリー

| ファイル | 変更内容 |
|---|---|
| `Sources/TextInputClient.swift` | `surroundingText(maxLength:)` を protocol + extension に追加 |
| `Sources/InputController.swift` | `IMKTextInputAdapter.surroundingText()` 実装、`GhostTextEngine` 統合、Tab ハンドリング |
| `Sources/GhostTextEngine.swift` | **新規**: debounce + FoundationModels + Task キャンセル管理 |
| `Sources/GhostTextWindow.swift` | **新規**: ゴーストテキスト描画 NSPanel |

---

## Tab キーの競合回避

PLAN260502 と同様。`isBracketMode` / `isSuccessorMode` が真のときは
`scheduleGhostTextIfNeeded` の guard で弾かれるため、同時に真になることはない。

| 条件 | Tab の動作 |
|---|---|
| `isBracketMode == true` | `selectNext`（既存） |
| `isSuccessorMode == true` | `selectNext`（既存） |
| `ghostTextEngine.hasGhostText` | `confirm` → 挿入（新規） |
| それ以外 | アプリに送る |

---

## プロンプト設計の留意点

Foundation Models のオンデバイスモデルは英語中心で日本語品質は未知数。
以下の点で調整が必要になる可能性がある。

| 問題 | 対策 |
|---|---|
| prefix をそのまま繰り返す | `postProcess` で先頭 prefix との重複を除去 |
| 改行・マークダウンを含む | `components(separatedBy: "\n").first` で1行目のみ使用 |
| 英語で返ってくる | プロンプトに「日本語で返してください」を追加 |
| 長すぎる補完 | `maximumResponseTokens: 30` で制限 |
| 不適切な補完が頻出 | `maxTokens` を 15 に下げて短い補完に特化する |

---

## 非対応・スコープ外

- ストリーミング表示（文字が順に現れる演出）: `session.streamResponse` で実装可能だが、30トークン程度なら一括で十分
- Apple Intelligence が無効な環境でのフォールバック（PLAN260502 の HTTP 版に切り替え等）
- 設定画面でのオン/オフ切り替え

---

## 懸念点・リスク

| 懸念 | 対策 |
|---|---|
| Apple Intelligence 非対応デバイス/macOS 非対応 | `isAvailable` フラグで全機能をスキップ。IME 本体に影響なし |
| 日本語補完品質が低い | プロンプト調整で改善を試みる。効果なければ PLAN260502（llama-server）に切り替え |
| `LanguageModelSession` が Swift 6 Sendable 非準拠の可能性 | `@MainActor` 内で完結するため、セッションをメインアクター上にのみ保持する設計で回避 |
| レスポンス速度（オンデバイス推論の遅延） | 400ms debounce のため打鍵中は発火しない。実測して遅ければ debounce を 600ms に延長 |
| `FoundationModels` API が beta 変更される可能性 | Step 2.5 で実機確認してから Step 3 を実装する。`respond(to:options:)` の引数シグネチャ・`response.content` プロパティ名は特に要確認 |
| `cursorRect()` がインデックス 0 固定（既存バグ） | Step 4-0 で `selectedRange().location` を使う形に修正済み（本プランのスコープ内）|

---

## 実装順序（推奨）

1. Step 1（TextInputClient 拡張）→ テストがコンパイルできることを確認
2. Step 2（GhostTextWindow）→ ビルドのみ確認
3. Step 3（GhostTextEngine）→ `SystemLanguageModel.default.availability` を print してモデルが使えるか確認
4. Step 4（InputController 統合）→ `/deploy` でインストール、手動テスト

手動テスト手順:
- テキストエディタに切り替え、日本語モードでローマ字を入力（例: `kyou`）
- 400ms 待機 → グレーのゴーストテキストが出現することを確認
- Tab キーで確定、別のキーでキャンセルされることを確認
- Apple Intelligence が無効の Mac でも IME が正常動作することを確認

---

## PLAN260502（HTTP）との実装差分

| 項目 | PLAN260502 | PLAN260502c |
|---|---|---|
| 推論バックエンド | `URLSession` → localhost:8080 | `LanguageModelSession` |
| モデル管理 | ユーザーが llama-server を起動 | OS 管理（不要） |
| プロンプト形式 | Qwen3 FIM トークン | 自然言語指示 |
| キャンセル | `Task.cancel()` → URLSession も中断 | `Task.cancel()` のみ |
| 追加依存 | なし（URLSession は標準） | `import FoundationModels`（macOS 26+） |
| `GhostTextWindow` | 同一 | 同一 |
| `InputController` 統合 | 同一 | 同一 |
