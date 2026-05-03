# Successor モード LLM 文脈深化

## 目的

`LLMSuccessorFetcher` が現状1語しか文脈として渡していない問題を解消する。
直前N語（最大3語）を渡し、表層語で候補を返すことで精度を改善する。

## 現状の課題

- `fetch(after word: String)` に直前1語だけ渡している
- プロンプトが「〇〇の直後に来る語」という1語文脈のみ
- 返り値がひらがな限定 → AzooKey で変換が必要で誤変換リスクがある
- 「今日の会議」と「重要な会議」で同じ候補が出る

## 方針

**A. 直前N語を渡す**（直前2〜3語を context として渡す）  
**C. 表層語で返す**（ひらがな縛りをなくし、漢字・カタカナ込みの語を受け取る）

## 変更箇所

### 1. `LLMSuccessorFetcher`

#### シグネチャ変更

```swift
// before
func fetch(after word: String, onResult: @escaping ([String]) -> Void)

// after
func fetch(context words: [String], onResult: @escaping ([String]) -> Void)
// words は確定語の直近順（末尾が最新）、最大3語
```

#### プロンプト変更

```swift
// before
「\(word)」の直後に来る日本語の語（名詞・動詞・形容詞）を5つ挙げてください。
各語はひらがなだけで書いてください。

// after
「\(contextPhrase)」に続く語を5つ挙げてください。
1語ずつ改行で出力してください。助詞は含めないでください。
```

`contextPhrase` は `words.joined(separator: "、")` で生成（例: `「報告、資料、会議」に続く語`）。

#### パーサー変更

`splitAndFilterHiraganaLines` → `splitAndFilterLines` にリネームし、ひらがな限定チェックを撤廃。
ただし空行・重複除去・最大5件は維持。記号のみや数字のみの行はフィルタする。

### 2. `InputController`（呼び出し側）（#6）

`applySuccessorLLMScheduling` の **`.pendingLowConfidence` と `.particlesOnly` の両ケース**で `fetch(after:)` を呼んでいる。**どちらの `case` も** `fetch(context:)` に切り替える（片方だけ残すと文脈が旧実装のままになる）。

`committedHistory` は `InputHandler` の `internal` プロパティで、同一モジュール内の `InputController` から `handler.committedHistory` として直接参照できる（別 getter は不要）。

```swift
// before（両経路）
Self.successorLLM.fetch(after: lastWord) { ... }

// after（両経路）
let ctx = Array(self.handler.committedHistory.suffix(3))
Self.successorLLM.fetch(context: ctx) { ... }
```

### 3. `SuccessorLLMTrigger` の非同期ガード（#1）

現状は `lastCommittedOutput == lastWord` でスナップショット比較しているが、文脈配列に変えると1語比較では不十分になる。

**設計**: トリガ生成時に `context = Array(handler.committedHistory.suffix(3))` を一度だけスナップショットし、`SuccessorLLMTrigger` の各ケースに `context: [String]` を乗せる。LLM コールバックでは **語順・要素数まで同一**であることを要求する。

```swift
// SuccessorLLMTrigger の変更
enum SuccessorLLMTrigger {
    case none
    case pendingLowConfidence(context: [String])  // lastWord 廃止
    case particlesOnly(context: [String])
}
```

コールバック先頭のガード（両経路共通の考え方）:

```swift
guard Array(self.handler.committedHistory.suffix(3)) == triggerContext else { return }
```

`suffix(3)` はトリガ記録時と同じ取り方に揃える（`context.count` だけ尾を取ると、トリガ時と異なるスライスになるため非推奨）。`suggestSuccessors()` で `.pendingLowConfidence` / `.particlesOnly` のどちらを立てる場合も **同じ `context` を埋める**。

### 4. LLM 表層語候補のデータモデル（#5）

表層語（漢字・カタカナ）は N-gram 保留表示の1打目フィルタ（`romajiToInitialKana` による読み前方一致）と噛み合わない。

**`successorLLMSurfaceExtras: [String]`** を `InputHandler` に追加し、LLM が返した表層形だけを保持する。

- `pendingSuccessorCandidates` … N-gram 由来のひらがな候補（従来どおり）。`InputHandler+SuccessorMode` の `mergePendingSuccessorMatches(dbOrdered:pending:romajiKey:)` の **`pending` 引数に渡すのはこちらだけ**とする
- `successorLLMSurfaceExtras` … **`mergePendingSuccessorMatches` には一切渡さない**。マージ結果に後から `append(contentsOf:)` する、または候補組み立て時に「DB マージ済み列 + surfaceExtras」を結合する
- ユーザーが1打目入力したとき、前方一致フィルタの対象は `dbOrdered` 側のみとし、`successorLLMSurfaceExtras` は **フィルタをかけずに常に候補末尾に残す**か、別 UI ルールを決める（後者は最小実装では「末尾固定でよい」）
- モード解除・確定・`commitComposition` 等で `pendingSuccessorCandidates` と **同時に** `removeAll()` / `= []`

## テスト方針

- `splitAndFilterLines` の単体テスト（空行・重複・記号フィルタを検証）
- `buildPrompt(context:)`（または `buildPrompt(words:)`）の出力文字列テスト（`contextPhrase` 生成の確認）（#7）
  - `private` のままでは同一モジュール外のテストターゲットから呼べないため、`LLMSuccessorFetcher.buildPrompt` を **`internal` に変更**し、テストから `@testable import keynaco`（実際のモジュール名に合わせる）で参照する
- `LLMSuccessorFetcher` の `fetch` / セッション呼び出しはオンデバイス LLM 依存のため単体テスト対象外

## 実装順序

1. `LLMSuccessorFetcher` のシグネチャ・プロンプト・パーサーを変更（`buildPrompt` を `internal` に）＋ テスト
2. `SuccessorLLMTrigger` の `lastWord` を `context: [String]` に変更
3. `InputController` の両経路（`.pendingLowConfidence` / `.particlesOnly`）を `fetch(context:)` に切り替え、コールバックのガード条件を配列比較に更新
4. `InputHandler` に `successorLLMSurfaceExtras` を追加し、候補表示と LLM コールバックを接続
5. 動作確認（EventViewerWindow でキャプチャ比較）
