# PLAN260502b — ゴーストテキスト推測変換（Qwen3 + llama.cpp + XPC Service）

作成日: 2026-05-02

---

## 概要

日本語 IME keynaco に、ローカル LLM（Qwen3 GGUF）を使ったゴーストテキスト補完機能を追加する。
IME メインプロセスとは別 XPC Service プロセスで推論を動かし、UI スレッドをブロックしない設計。

```
[アプリ] ←NSXPCConnection→ [LLMService XPC] → llama.cpp → Qwen3 GGUF
    ↓ (Tab確定)
ghostText overlay (NSWindow)
```

---

## 技術的制約の整理

### App Sandbox
- 現状の entitlements: `app-sandbox=true` + `files.user-selected.read-write`
- XPC Service も同一サンドボックスに属し、独立したコンテナを持つ
- GGUF ファイル（最大数 GB）を XPC Service から読むには **App Group** 経由が最も堅実

### Swift 6 Strict Concurrency
- `InputController` は `@MainActor`
- `GhostTextController`（新規）はメインスレッドから呼ばれるが、XPC 応答は非メインスレッドで返る
- `Task { @MainActor in … }` で収束

### llama.cpp のリンク方法
公式リポジトリ（https://github.com/ggml-org/llama.cpp）は Package.swift を持つが
巨大かつ Swift Package としての安定度は低め。推奨は **手動 C ライブラリ + Bridging Header**:

1. `llama.cpp` / `ggml.c` 他の必要ファイルをサブディレクトリ `LLMService/llama/` に置く
2. XPC Service ターゲットでそのまま C/C++ ソースとしてコンパイル
3. `llama_bridge.h` をブリッジングヘッダとして指定

SPM 代替案: `swift-llama`（`https://github.com/rehatkathuria/swift-llama`）を Package として追加し、
XPC Service ターゲットのみ依存させる。ただし依存バージョン管理が必要。

---

## ファイル構成（追加・変更）

```
keynaco/
├── project.yml                        ← LLMService ターゲット追加
├── Sources/
│   ├── keynaco.entitlements           ← App Group 追加
│   ├── GhostTextController.swift      ← NEW: XPCクライアント + Debounce
│   ├── GhostTextWindow.swift          ← NEW: オーバーレイ UI
│   └── InputController.swift          ← 変更: GhostText 統合
├── LLMService/
│   ├── LLMService.entitlements        ← NEW: XPC Service 用 entitlements
│   ├── LLMServiceMain.swift           ← NEW: XPC Service エントリポイント
│   ├── LLMServiceDelegate.swift       ← NEW: NSXPCListenerDelegate
│   ├── LLMPredictionService.swift     ← NEW: プロトコル実装 (llama.cpp 呼び出し)
│   ├── LLMPredictionServiceProtocol.swift ← NEW: @objc protocol (共有)
│   └── llama/                         ← llama.cpp C ソース一式
│       ├── llama.h / llama.cpp
│       ├── ggml.h / ggml.c / ggml-*.c
│       └── llama_bridge.h             ← Swift 向けブリッジングヘッダ
└── Tests/
    └── GhostTextControllerTests.swift ← NEW
```

---

## 実装ステップ

### Step 1: App Group 設定

**Sources/keynaco.entitlements** に追加:
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>com.yusuke.inputmethod.keynaco.shared</string>
</array>
```

**LLMService/LLMService.entitlements**（新規）:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" …>
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>com.yusuke.inputmethod.keynaco.shared</string>
    </array>
</dict>
</plist>
```

モデルファイルの置き場所（ユーザーが手動コピー、または設定画面で選択）:
```
~/Library/Group Containers/com.yusuke.inputmethod.keynaco.shared/models/qwen3.gguf
```

### Step 2: XPC プロトコル定義

`LLMService/LLMPredictionServiceProtocol.swift`（両ターゲットで共有）:
```swift
import Foundation

@objc protocol LLMPredictionServiceProtocol {
    /// FIM 形式で推論を要求する。結果は reply で非同期返却（nil = 失敗/キャンセル）。
    func predict(prefix: String, suffix: String, reply: @escaping (String?) -> Void)
    /// 実行中の推論を中断する。
    func cancelPrediction()
}
```

### Step 3: project.yml への XPC Service ターゲット追加

```yaml
packages:
  AzooKeyKanaKanjiConverter: …  # 既存

targets:
  keynaco:                       # 既存
    …
    dependencies:
      - sdk: InputMethodKit.framework
      - sdk: libsqlite3.tbd
      - package: AzooKeyKanaKanjiConverter
        product: KanaKanjiConverterModuleWithDefaultDictionary
      - target: LLMService       # ← 追加: バンドル埋め込み

  LLMService:                    # ← 新規
    type: xpc-service
    platform: macOS
    sources:
      - path: LLMService
        excludes:
          - llama                # C ソースは別扱い
      - path: LLMService/llama  # C/C++ ソース
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.yusuke.inputmethod.keynaco.llmservice
        SWIFT_VERSION: "6.0"
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        CODE_SIGN_ENTITLEMENTS: LLMService/LLMService.entitlements
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: R2ZZ3ALJ36
        SWIFT_OBJC_BRIDGING_HEADER: LLMService/llama/llama_bridge.h
        GCC_ENABLE_CPP_EXCEPTIONS: YES
        CLANG_CXX_LANGUAGE_STANDARD: "c++17"

  keynacoTests: …               # 既存
```

### Step 4: llama.cpp の組み込み

llama.cpp の最小セット（single-file build 版 `llama.cpp` の利用が最も簡単）:

```
LLMService/llama/
├── llama.h
├── llama.cpp        # 本体（ggml を内包した amalgamation を推奨）
└── llama_bridge.h   # Swift Bridging Header
```

`llama_bridge.h`:
```c
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#include "llama.h"
#ifdef __cplusplus
}
#endif
```

> **実用的な取得方法**: llama.cpp リリースページから `llama-<version>-src.zip` をダウンロードし、
> `llama.h`, `llama.cpp`, `ggml.h/c`, `ggml-alloc.c`, `ggml-backend.c`, `ggml-quants.c` を使う。
> または `llama.cpp` の `-DLLAMA_BUILD_SERVER=OFF -DBUILD_SHARED_LIBS=OFF` で静的ライブラリを
> ビルドし、Xcode の "Link Binary With Libraries" に追加する方法でも可。

### Step 5: XPC Service 実装

`LLMService/LLMServiceMain.swift`:
```swift
import Foundation

// XPC Service エントリポイント
let delegate = LLMServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
```

`LLMService/LLMServiceDelegate.swift`:
```swift
import Foundation

final class LLMServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: LLMPredictionServiceProtocol.self)
        connection.exportedObject = LLMPredictionService()
        connection.resume()
        return true
    }
}
```

`LLMService/LLMPredictionService.swift`:
```swift
import Foundation

final class LLMPredictionService: NSObject, LLMPredictionServiceProtocol {

    private var ctx: OpaquePointer? = nil   // llama_context*
    private var model: OpaquePointer? = nil // llama_model*
    private var isCancelled = false

    override init() {
        super.init()
        loadModel()
    }

    private func loadModel() {
        let groupID = "com.yusuke.inputmethod.keynaco.shared"
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return }
        let modelURL = containerURL
            .appendingPathComponent("models")
            .appendingPathComponent("qwen3.gguf")
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return }

        llama_backend_init()
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 0  // CPU only（Metal は後続で有効化可能）
        model = llama_load_model_from_file(modelURL.path, mparams)
        guard let model else { return }
        var cparams = llama_context_default_params()
        cparams.n_ctx = 512
        cparams.n_threads = 4
        ctx = llama_new_context_with_model(model, cparams)
    }

    func predict(prefix: String, suffix: String, reply: @escaping (String?) -> Void) {
        guard let ctx else { reply(nil); return }
        isCancelled = false

        // Qwen3 FIM プロンプト構築
        let prompt = "<|fim_prefix|>\(prefix)<|fim_suffix|>\(suffix)<|fim_middle|>"
        let stopTokens = ["\n", "<|endoftext|>", "<|fim_pad|>"]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { reply(nil); return }
            let result = self.runInference(prompt: prompt, maxTokens: 30, stopTokens: stopTokens)
            reply(self.isCancelled ? nil : result)
        }
    }

    func cancelPrediction() {
        isCancelled = true
    }

    private func runInference(prompt: String, maxTokens: Int, stopTokens: [String]) -> String? {
        guard let ctx, let model else { return nil }

        // トークナイズ
        let nPrompt = -llama_tokenize(model, prompt, Int32(prompt.utf8.count), nil, 0, true, true)
        var tokens = [llama_token](repeating: 0, count: Int(nPrompt))
        llama_tokenize(model, prompt, Int32(prompt.utf8.count), &tokens, nPrompt, true, true)

        // バッチ評価
        llama_kv_cache_clear(ctx)
        var batch = llama_batch_get_one(&tokens, Int32(tokens.count))
        guard llama_decode(ctx, batch) == 0 else { return nil }

        var result = ""
        for _ in 0..<maxTokens {
            if isCancelled { return nil }
            guard let logits = llama_get_logits(ctx) else { break }

            // Greedy サンプリング
            let nVocab = Int(llama_n_vocab(model))
            let nextToken = (0..<nVocab).max(by: { logits[$0] < logits[$1] }).map { llama_token($0) } ?? 0

            if nextToken == llama_token_eos(model) { break }

            // トークン→文字列
            var buf = [CChar](repeating: 0, count: 64)
            let len = llama_token_to_piece(model, nextToken, &buf, 64, 0, false)
            if len > 0 {
                let piece = String(bytes: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
                result += piece
                if stopTokens.contains(where: { result.hasSuffix($0) }) { break }
            }

            var t = nextToken
            batch = llama_batch_get_one(&t, 1)
            if llama_decode(ctx, batch) != 0 { break }
        }
        return result.trimmingCharacters(in: .newlines)
    }
}
```

> **NOTE**: 上記は greedy decoding のシンプル実装。温度サンプリング等は追って拡張可能。

### Step 6: GhostTextController（XPC クライアント + Debounce）

`Sources/GhostTextController.swift`:
```swift
import Foundation
import AppKit

/// IME 側から XPC Service を呼び出す Debounce コントローラ。
/// InputController（@MainActor）から利用する。
@MainActor
final class GhostTextController {

    static let shared = GhostTextController()

    private var connection: NSXPCConnection?
    private var debounceTask: Task<Void, Never>?
    private let ghostWindow = GhostTextWindow()

    /// 予測テキスト。Tab キーで確定、次のキーでキャンセル。
    private(set) var pendingGhost: String? = nil

    private init() { setupConnection() }

    private func setupConnection() {
        let conn = NSXPCConnection(serviceName: "com.yusuke.inputmethod.keynaco.llmservice")
        conn.remoteObjectInterface = NSXPCInterface(with: LLMPredictionServiceProtocol.self)
        conn.resume()
        connection = conn
    }

    /// キーが入力されるたびに呼び出す。
    /// - prefix: カーソル前テキスト
    /// - suffix: カーソル後テキスト
    /// - cursorRect: ゴーストテキスト表示位置
    func requestPrediction(prefix: String, suffix: String, cursorRect: NSRect) {
        cancelGhost()

        debounceTask = Task { [weak self] in
            guard let self else { return }
            // 400ms 待機
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }

            await self.fetchPrediction(prefix: prefix, suffix: suffix, cursorRect: cursorRect)
        }
    }

    /// Tab キーが押されたとき。ghost テキストを返して確定処理を委譲。
    func confirmGhost() -> String? {
        let text = pendingGhost
        cancelGhost()
        return text
    }

    /// 次のキー入力時にゴーストをキャンセルする。
    func cancelGhost() {
        debounceTask?.cancel()
        debounceTask = nil
        if let svc = connection?.remoteObjectProxy as? LLMPredictionServiceProtocol {
            svc.cancelPrediction()
        }
        pendingGhost = nil
        ghostWindow.hide()
    }

    private func fetchPrediction(prefix: String, suffix: String, cursorRect: NSRect) async {
        guard let svc = connection?.remoteObjectProxy(withErrorHandler: { _ in }) as? LLMPredictionServiceProtocol else { return }

        await withCheckedContinuation { continuation in
            svc.predict(prefix: prefix, suffix: suffix) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, let result, !result.isEmpty else {
                        continuation.resume()
                        return
                    }
                    self.pendingGhost = result
                    self.ghostWindow.show(text: result, near: cursorRect)
                    continuation.resume()
                }
            }
        }
    }
}
```

### Step 7: GhostTextWindow（オーバーレイ UI）

`Sources/GhostTextWindow.swift`:
```swift
import AppKit

/// カーソル右側にグレーのゴーストテキストをオーバーレイ表示する透明ウィンドウ。
final class GhostTextWindow: NSWindow {

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: true)
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary]

        label.font = .systemFont(ofSize: 15)
        label.textColor = .tertiaryLabelColor  // グレー
        label.backgroundColor = .clear
        label.isBordered = false
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: contentView!.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor, constant: -2),
        ])
    }

    func show(text: String, near cursorRect: NSRect) {
        label.stringValue = text
        label.sizeToFit()
        let width = label.frame.width + 4
        let height = cursorRect.height > 0 ? cursorRect.height : 20
        // カーソル矩形の右端 + 2px に表示
        let origin = NSPoint(x: cursorRect.maxX + 2, y: cursorRect.minY)
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        orderFront(nil)
    }

    func hide() {
        orderOut(nil)
        label.stringValue = ""
    }
}
```

### Step 8: InputController への統合

`InputController.swift` の `handle(_:client:)` メソッドを修正する。

**Tab キー処理（ゴースト確定）**:
```swift
// handle() の先頭付近、isSuccessorMode チェックの前に挿入
if event.keyCode == KeyCode.tab,
   let ghostText = GhostTextController.shared.confirmGhost() {
    let adapter = IMKTextInputAdapter(sender)
    adapter.insertText(ghostText)
    return true  // consumed
}

// それ以外のキー入力時はゴーストをキャンセル
if event.keyCode != KeyCode.tab {
    GhostTextController.shared.cancelGhost()
}
```

**通常入力後の予測リクエスト**:
```swift
// handle() の最後（candidateAction を返す直前）でゴースト予測をトリガー
// 組成中かつ候補ウィンドウが非表示のとき
if !InputHandler.isAsciiMode,
   !handler.state.composingText.isEmpty,
   !candidateWindow.isVisible {
    let adapter = IMKTextInputAdapter(sender)
    let cursorRect = adapter.cursorRect()
    // カーソル前後のテキストを取得
    let prefix = buildGhostPrefix(handler: handler, sender: sender)
    let suffix = buildGhostSuffix(sender: sender)
    GhostTextController.shared.requestPrediction(prefix: prefix, suffix: suffix, cursorRect: cursorRect)
}
```

**プレフィックス / サフィックスの構築**:
```swift
private func buildGhostPrefix(handler: InputHandler, sender: Any?) -> String {
    // 直近の確定テキスト + 現在の組成テキスト
    let committed = handler.committedHistory.joined()
    let composing = handler.state.composingText
    return committed + composing
}

private func buildGhostSuffix(sender: Any?) -> String {
    // IMKTextInput からカーソル後テキストを取得（未サポートアプリでは空文字）
    guard let client = sender as? IMKTextInput else { return "" }
    let range = client.selectedRange()
    guard range.location != NSNotFound else { return "" }
    // 最大 50 文字だけ取得
    let suffixRange = NSRange(location: range.location, length: 50)
    return (client.attributedSubstring(from: suffixRange)?.string) ?? ""
}
```

---

## Tab キーの競合について

現状 `KeyCode.tab`（48）は後続語サジェスト（SuccessorMode）で使われていない。
ただし `handleCandidateVisible` 内では未処理（`default` ケース）に落ちる可能性がある。

ゴーストテキスト確定のトリガーを Tab に設定する場合:
- **候補ウィンドウが非表示のとき** のみゴーストテキストを確定する
- 候補ウィンドウが表示中の Tab は従来通りスルー（アプリ側に送る）

---

## カーソル位置の精度向上

`IMKTextInputAdapter.cursorRect()` は現状 `characterIndex: 0` で取得しているため、
カーソル位置がずれる。組成テキストの末尾に対応する rect を取得するよう修正する:

```swift
func cursorRect() -> NSRect {
    var rect = NSRect.zero
    // 組成テキスト末尾のインデックスで矩形を取得
    let idx = (client?.selectedRange().location ?? 0)
    client?.attributes(forCharacterIndex: max(0, idx), lineHeightRectangle: &rect)
    if rect == .zero {
        client?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
    }
    return rect
}
```

---

## モデル選択の指針

| モデル | ファイルサイズ | 推論速度 (M1) | 日本語品質 |
|--------|-------------|-------------|-----------|
| Qwen3-0.6B-Q4_K_M | ~400MB | 60+ tok/s | △（文補完程度） |
| Qwen3-1.7B-Q4_K_M | ~1.1GB | 30+ tok/s | ○（実用的） |
| Qwen3-4B-Q4_K_M   | ~2.5GB | 15+ tok/s | ◎（高品質） |

400ms debounce + 30 トークン = 実測 1 秒未満を狙うなら **1.7B** が実用バランス。

GGUF ファイルは [Hugging Face](https://huggingface.co/Qwen) から取得。
`~/Library/Group Containers/com.yusuke.inputmethod.keynaco.shared/models/qwen3.gguf` に配置。

---

## 推論パラメータ（llama.cpp C API）

```c
// サンプリング設定
llama_sampler* sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.3));      // 低温: 確定的な補完
llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40));
llama_sampler_chain_add(sampler, llama_sampler_init_dist(42));

// n_predict = 30（最大生成トークン数）
// Stop トークン: "\n", "<|endoftext|>", "<|fim_pad|>"
```

---

## 実装順序と作業量見積

| # | 作業 | 工数 | 依存 |
|---|------|------|------|
| 1 | project.yml + entitlements 設定 | 1h | - |
| 2 | XPC Service ターゲット骨格 (main, delegate) | 2h | 1 |
| 3 | llama.cpp ソース取得・ビルド確認 | 3h | 2 |
| 4 | `LLMPredictionService` 推論実装 | 4h | 3 |
| 5 | `GhostTextWindow` UI | 1h | - |
| 6 | `GhostTextController` XPC クライアント | 2h | 4, 5 |
| 7 | `InputController` 統合・Tab キー処理 | 2h | 6 |
| 8 | 設定画面: モデルファイルパス選択 | 2h | 1 |
| 9 | 動作確認・微調整 | 3h | 7, 8 |

合計 **約 20h**。

---

## 実装許可を求める変更点

以下のファイル・ターゲットを新規作成・変更します。実装を始める前に確認をお願いします。

1. **`project.yml`** — `LLMService` XPC Service ターゲット追加、`keynaco` への依存追加
2. **`Sources/keynaco.entitlements`** — `com.apple.security.application-groups` 追加
3. **`LLMService/`** ディレクトリ新規作成（XPC Service ソース一式）
4. **`Sources/GhostTextController.swift`** 新規作成
5. **`Sources/GhostTextWindow.swift`** 新規作成
6. **`Sources/InputController.swift`** — Tab キー処理・予測リクエスト追加
7. **`Sources/TextInputClient.swift`** — `cursorRect()` 精度改善

llama.cpp ソースの取得方法（手動 or SPM）と
モデルファイルの配置場所についても合わせて確認させてください。
