# セグメントモード ガタつき解消 — 実装方針と調査結果

元アイデア: [`ideas/IDEA260513b.md`](../ideas/IDEA260513b.md)

---

## 目標

Space 押下時のセグメント分割で「AzooKey の粗い分割 → LLM 分割に上書き」というガタつきをなくし、
分割結果を一発で正しく表示する。

---

## 調査で確定したリスク

### DispatchSemaphore 案はデッドロックする（採用不可）

アイデアで提案されていた `inferSynchronously()` + `DispatchSemaphore` は、
以下の理由で必ずデッドロックする。

```
InputController: @MainActor クラス（InputController.swift:104）
  └─ handle(event:client:)  ← MainActor 上で実行（:316）
       └─ enterSegmentMode() 内で DispatchSemaphore.wait() ← MainActor をブロック

LLMSegmentConverter: @MainActor クラス（LLMSegmentConverter.swift:5）
  └─ Task { @MainActor ... } の完了コールバックが MainActor に戻ろうとする
       └─ MainActor は .wait() でブロック中 → 永遠に完了しない
```

`handle(event:client:)` と `LLMSegmentConverter` の両方が `@MainActor` に乗っており、
同一スレッドのブロッキング待ちになるため回避不可。

### handle(event:client:) を async にはできない

IMK は ObjC ランタイムから `handle()` を呼ぶ。Swift async 関数は ObjC から呼べないため、
`handle()` 自体を `async` にする案も使えない。

### LanguageModelSession を毎回生成している

`LLMSegmentConverter.convert()` は呼ぶたびに `LanguageModelSession` を new instance している
（`LLMSegmentConverter.swift:24`）。  
`LLMMisconversionChecker` は `lazy var session` で再利用しており（`LLMMisconversionChecker.swift:9`）、
こちらの方が効率的。セグメント変換でも session を再利用できる余地がある。

---

## 実装方針（2 案）

### 案 A: Task.detached ブリッジ

`LLMSegmentConverter` の `@MainActor` 制約を外し、`Task.detached` で MainActor 外のスレッドで
LLM 推論を走らせる。そこで `withCheckedContinuation` を使って同期待ちする。

```
handle(event:client:)  @MainActor
  └─ Task.detached (non-actor)
       ├─ azooKeySegmentize()
       ├─ LLM.infer()  ← non-actor スレッドで完結、タイムアウト付き
       └─ await MainActor.run { applyResult() }  ← 終わってから MainActor に戻る
```

**課題**: `LLMSegmentConverter` の `@MainActor` を外す設計変更が必要。
`InputHandler`（struct）への書き戻しが `await MainActor.run` 越しになる。  
`handle()` の `return Bool` が Task 完了前に返るため、キーイベントの返り値が常に `true` 固定になる。

### 案 B: プリフェッチ（推奨）

**composedHiragana が N 文字を超えた時点**で LLM を先行起動する。
Space 押下時に完了していれば採用、未完了なら即座に AzooKey fallback とする。

```
ひらがな入力中（N 文字超えた瞬間）
  └─ LLMSegmentConverter.prefetch(hiragana: currentReading, ...) を非同期起動

Space 押下（セグメントモード）
  ├─ prefetch 完了済みなら → 即座に LLM 境界を適用
  └─ 未完了なら → 即座に AzooKey パスへ fallback（現行動作と同じ）
```

> **注意**: 「未完了なら N ms 待ち」はしない。`handle()` は `@MainActor` のため、
> ここでブロックすると LLM の完了コールバック（同じく `@MainActor`）が返れなくなり
> DispatchSemaphore 案と同じデッドロックが発生する。

**prefetch のトリガー条件（候補）**:

| トリガー | 特徴 |
|---------|------|
| composedHiragana が **5 文字超**になった時点 | シンプル。短い単語は対象外でよい |
| タイピングが **200ms 停止**した時点 | より自然だが、タイマー管理が必要 |

まず「5 文字超」で実装し、fallback 頻度を実測してから改善する。

**メリット**:
- 既存の非同期構造（`@MainActor` + Task）を変えない
- 待ち時間が「入力 → Space 間の時間」に隠れるため体感ゼロに近い
- デッドロックリスクなし

**課題**:
- 入力が短い（5 文字以下）場合は常に fallback（現行動作と同じ）
- 入力途中で読みが変わると prefetch の結果が無効になる（→ `cancel()` と再起動が必要）

---

## 推奨: 案 B を採用し、まず計測から始める

### 計測すべき数値

| 計測項目 | 目的 |
|---------|------|
| 入力開始 → Space 間の平均時間 | prefetch の猶予時間 |
| LLM 推論の平均レイテンシ（実機） | prefetch で間に合うか判断 |
| LLM 推論の P95 レイテンシ | fallback 頻度の見積もり |

macOS 26 の実機で `LLMSegmentConverter` に `os_signpost` を仕込んで Instruments で計測するのが
最も確実。

### 実装ステップ（案 B）

#### Step 1: LanguageModelSession の再利用

`LLMSegmentConverter` の session を `lazy var` に変更し、毎回生成しない。
`LLMMisconversionChecker.swift:9` の実装パターンを参考にする。

```swift
// Before（毎回生成）
let session = LanguageModelSession(model: SystemLanguageModel.default) { ... }

// After（再利用）
private lazy var session: LanguageModelSession = LanguageModelSession(model: SystemLanguageModel.default) { ... }
```

#### Step 2: prefetch API の追加

```swift
// LLMSegmentConverter に追加
public func prefetch(hiragana: String, azooKey: AzooKeyConverter, leftSideContext: String) {
    cancel()
    prefetchTask = Task { @MainActor [weak self] in
        guard let self else { return }
        // 既存の LLM 推論ロジック
        self.cachedResult = try? await self.session.respond(to: prompt)
    }
}

public func consumePrefetch() -> [SegmentPair]? {
    defer { cachedResult = nil; prefetchTask = nil }
    return cachedResult.flatMap { parse($0) }
}
```

#### Step 3: InputController での接続

```swift
// キー入力のたびに（handle 内、ひらがな追記後）
if handler.composedHiragana.count > 5 {
    Self.segmentLLM.prefetch(hiragana: handler.composedHiragana, ...)
}
// ※ 文字が削除されたり読みが変わった場合は cancel() → 再起動

// Space 押下時（enterSegmentMode 内）
if let pairs = Self.segmentLLM.consumePrefetch() {
    applyLLMBoundaries(pairs: pairs, ...)
} else {
    // 即座に AzooKey パスへ fallback（ブロッキングなし）
}
```

#### Step 4: 既存の非同期上書きパスを削除

| 削除対象 | 場所 |
|---------|------|
| `applyLLMSegmentResult()` | InputController |
| `segmentLLMTrigger` プロパティ | InputController / InputHandler |
| `applyLLMScheduling()` のセグメント分呼び出し | InputController |

---

## 保留事項

- **LLM レイテンシ計測前に実装しない**: 計測結果次第で prefetch トリガーの文字数閾値を調整する
- **案 A への切り替え条件**: 計測で「LLM レイテンシ > 入力 → Space 間の時間」が常態化する場合は
  prefetch が構造的に間に合わないため、案 A（Task.detached）を再検討する
- **`tryManualBisection()` の促音ヒューリスティック削除**: LLM 精度の実測後に判断

---

## 影響しないコンポーネント

- `LLMSuccessorFetcher`（Successor モード）: 非同期のままで変更不要
- `LLMMisconversionChecker`: 変更不要
- `AzooKeyConverter` の `segmentize`: fallback パスで引き続き使用
