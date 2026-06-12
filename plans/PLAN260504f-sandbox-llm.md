# IME サンドボックスへの LLM 統合

## 背景

`DebugSocketServer`（`keynaco-ime-sandbox` スキルが使うソケットサーバー）は `InputHandler` を直接持つが、LLM コンポーネント（`LLMSuccessorFetcher` / `LLMSegmentConverter` / `LLMCandidateScorer`）が動いていない。

`InputController` はキー処理後に `applySuccessorLLMScheduling` / `applySegmentLLMScheduling` / `applyCandidateScorerScheduling` を呼んで LLM を起動するが、`DebugSocketServer` にはその仕組みがない。

## 目的

`DebugSocketServer` でも LLM が非同期で動き、候補リストに反映されるようにする。

## 設計方針

### LLM は非同期のまま扱う

ソケット通信は request-response だが、LLM 結果は非同期。
キー処理のレスポンスは LLM 起動前の状態を返し、クライアントは後から `state` コマンドでポーリングして LLM 反映後の状態を取得する。これは `InputController` の実際の挙動（LLM は別タスク・候補ウィンドウを後で更新）と一致する。

### `pendingLowConfidence` の制約（既知）

`InputController` と同様、`.pendingLowConfidence` のコールバックは `handler.successorLLMSurfaceExtras` にだけ追記する。extras は **次のキー処理で `mergePendingSuccessorMatches` が呼ばれるまで `candidates` には現れない**。つまり `state` ポーリングをしても `candidates` 配列はすぐ変わらず、extras だけが増えた状態になる。

デバッグ可視性のため `makeResponse` に `successorLLMSurfaceExtras` フィールドを追加し、ポーリングで extras を観察できるようにする。

### 3 種の LLM を対称に実装（InputController と同順）

Successor → Segment → CandidateScorer の順で `applyLLMScheduling()` から呼ぶ。

| LLM | 役割 | 副作用 |
|-----|------|--------|
| `LLMSuccessorFetcher` | 後続語候補の表層形追加 | `handler.successorLLMSurfaceExtras` に追記 / `.particlesOnly` は `candidateWindow.apply(.show(...))` + `mockClient.setMarkedText` |
| `LLMSegmentConverter` | セグメントモードの全文変換 | `handler.applyLLMSegmentResult` → `candidateWindow.apply(action)` + `mockClient` で `applySegmentMarkedText` |
| `LLMCandidateScorer` | 通常変換候補の並べ替え | `candidateWindow.moveRow(from:)` + `mockClient.setMarkedText`（候補選択と markedText を一致させる） |

## 変更ファイル

### `Sources/Debug/DebugSocketServer.swift`

**`DebugSocketServer` プロパティ追加:**

```swift
private let successorLLM = LLMSuccessorFetcher()
private let segmentLLM = LLMSegmentConverter()
private let candidateScorer = LLMCandidateScorer()
```

**`processCommand` の reset ブランチ:**

LLM キャンセルと scorer リセットを追加する。

```swift
successorLLM.cancel()
segmentLLM.cancel()
candidateScorer.cancel()
handler.resetScorerPending()
```

**`processCommand` のキーイベント処理:**

`candidateWindow.apply(action: action)` の直後に呼ぶ。

```swift
applyLLMScheduling()
```

**`makeResponse` への追加フィールド:**

`successorLLMSurfaceExtras` を DEBUG 限定フィールドとして追加し、extras をポーリングで観察できるようにする。

```swift
"successorLLMSurfaceExtras": handler.successorLLMSurfaceExtras,
```

**`applyLLMScheduling()` メソッド:**

```swift
private func applyLLMScheduling() {
    applySuccessorLLMScheduling()
    applySegmentLLMScheduling()
    applyCandidateScorerScheduling()
}
```

**`applySuccessorLLMScheduling()` メソッド:**

- `handler.successorLLMTrigger` を読み取り、**直後に `.none` にクリア**する
- `context words`（第1引数）← `triggerContext`（トリガが持つ語列）
- `documentContextPrefix`（第2引数）← `handler.committedHistory.suffix(5).joined()`（surroundingContext なし）
- `.pendingLowConfidence`:
  - コールバックで `handler.successorLLMSurfaceExtras` に追記
  - `candidates` への反映は次のキー処理まで遅延（設計方針の制約を参照）
- `.particlesOnly`:
  - コールバック先頭で **`InputController` L550–552 と同一のガード**を必ず入れる（抜けると `successorLLMBaseCandidates` が `nil` のときにクラッシュ）:
    - `handler.isSuccessorMode`
    - `candidateWindow.isVisible`
    - `let base = handler.successorLLMBaseCandidates`
  - コールバックで `merged` を組み立て、`candidateWindow.apply(.show(...))` で候補ウィンドウ更新
  - その後 `mockClient.setMarkedText(selectedText, ...)` で markedText を候補と一致させる（Electron 対策と同じ考え方）

**`applySegmentLLMScheduling()` メソッド:**

- `handler.segmentLLMTrigger` が `.start(hiragana:)` なら、**直後に `.none` にクリア**してから `segmentLLM.convert(...)` を起動
- コールバックは `InputController.applySegmentLLMScheduling` と同等
  - `handler.applyLLMSegmentResult(text:)`
  - `handler.makeCandidateActionForFocusedSegment()` → `candidateWindow.apply(action)`
  - `handler.applySegmentMarkedText(client: mockClient)`

**`applyCandidateScorerScheduling()` メソッド:**

- 冒頭で `candidateScorer.cancel()`
- `handler.lastScorerEligible` / `pendingScorerGlobalIndices` / `isExplicitlySelected` / モードフラグのガードは `InputController` と同等
- 文脈は `handler.committedHistory.suffix(5).joined()`（surroundingContext なし）
- コールバック:
  - `candidateWindow.moveRow(from: g)` で候補を並べ替え
  - `mockClient.setMarkedText` で markedText を現在選択候補に更新

**`DebugCandidateWindow` への `moveRow` 追加:**

`CandidateWindow.moveRow(from:)` と同等のロジックを `mutating func moveRow(from: Int)` として実装。

- **`candidates` を変更する前に** `let keepText = selectedText` で現在の選択文字列を捕捉する（`selectedText` は `isVisible` 等に依存するため、`remove`/`insert` 後に読むと意図しない値になる）
- `candidates[from]` を取り出して `predictionEnd` 位置に挿入
- `fromHistoryBand`（`predictionEnd <= from < historyEnd`）なら `predictionEnd += 1`
- `fromAzooBand`（`from >= historyEnd`）なら `predictionEnd += 1`, `historyEnd += 1`
- 元の選択テキストを保持（`keepText` があれば `firstIndex(of:)` で `selectedRow` を再設定）

## 実装メモ（レビュー反映）

### `updateMockMarkedText` / セグメント marked text と型

[`TextInputClient`](Sources/TextInputClient.swift) には `setMarkedText(_: NSAttributedString, selectionRange:)` がプロトコル要件としてあり、`extension TextInputClient` のデフォルト実装が **`text.string` を String 版 `setMarkedText` に委譲**する（L14–18）。そのため `SocketMockClient` が String 版だけを実装していても、`handler.state.segmentState` 経由の `ss.attributedString(...)` を `mockClient` に渡す呼び出しはコンパイル可能。

明示的に文字列へ落としたい場合は `mockClient.setMarkedText(str.string, selectionRange: NSRange(location: str.length, length: 0))` としてもよい（`str` は `NSAttributedString`。`location` は `str.string.utf16.count` がより厳密だが、本用途は InputController と同様 `str.length` でよい）。

### `.particlesOnly` のガード

上記「`applySuccessorLLMScheduling`」の箇条書きに記載のとおり、`InputController` と同一の 3 条件をコールバック先頭に入れること。

### `moveRow` の `keepText` 捕捉タイミング

上記「`DebugCandidateWindow` への `moveRow`」のとおり、リスト変更前に `let keepText = selectedText` とする。

## 注意事項

- `DebugSocketServer` は `@MainActor` なので LLM のコールバックもメインスレッドで受け取れる
- LLM の可用性チェック（`SystemLanguageModel.default.availability`）は各 LLM クラス内で行うため `DebugSocketServer` 側では不要
- `LLMMisconversionChecker` はサンドボックスでは不要（確定後の誤変換検出はデバッグ目的でなくユーザー通知機能のため）
- `IMESandboxWindow` は `InputController` 経由なので変更不要（すでに LLM 結果が反映されている）

## スコープ外

- `DebugSocketServer` のプロトコルに LLM 結果のプッシュ通知を追加（WebSocket 化など）— ポーリングで十分
- `IMESandboxWindow` への変更 — 既に動いている
