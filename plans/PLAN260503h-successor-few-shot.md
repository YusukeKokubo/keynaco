# LLMSuccessorFetcher への few-shot 注入 ✅ 実装完了（2026-05-03）

## 目的

`LLMSuccessorFetcher` が現状「直近3語」だけを文脈として後続語を生成している。
ユーザーの bi-gram 履歴を few-shot として渡し、**そのユーザーが直前語の後によく使う語**を
LLM が把握したうえで候補を生成できるようにする。

## `LLMCandidateScorer` との違い

| | LLMCandidateScorer | LLMSuccessorFetcher |
|---|---|---|
| タスク | **選択**（候補リストから1件選ぶ） | **生成**（後続語を5件列挙する） |
| few-shot の役割 | 「このユーザーはXの後にYを選ぶ」と教える | 「このユーザーはXの後にY,Z...をよく使う」と教える |
| プロンプト形式 | 各ペアを1行ずつ列挙 | 直前語に対するtop語をカンマ区切りで1行にまとめる |

生成タスクなので、複数の next をまとめて「よく使う語リスト」として見せる方が LLM に伝わりやすい。

## 変更箇所

### 1. `LLMSuccessorFetcher.fetch()` のシグネチャ変更

```swift
// before
func fetch(context words: [String], onResult: @escaping ([String]) -> Void)

// after
func fetch(context words: [String], examples: [(prev: String, next: String)], onResult: @escaping ([String]) -> Void)
```

### 2. `LLMSuccessorFetcher.buildPrompt()` の変更

```swift
// before
nonisolated internal static func buildPrompt(words: [String]) -> String

// after
nonisolated internal static func buildPrompt(words: [String], examples: [(prev: String, next: String)]) -> String
```

プロンプト構造（`examples` が空でないときのみ傾向セクションを挿入）:

```
【このユーザーが「会議」の後によく使う語】
資料、議事録、メモ、確認、準備

「報告、資料、会議」に続く語を5つ挙げてください。
1語ずつ改行で出力してください。助詞は含めないでください。
```

`examples` は同じ `prev` のみを想定（直前語 1 語分の bi-gram top）。
`prev` 表示は `examples.first?.prev`、`next` 列は `examples.map(\.next).joined(separator: "、")`。

### 3. `InputController.applySuccessorLLMScheduling()` の変更

両ケース（`.pendingLowConfidence` / `.particlesOnly`）の `fetch` 呼び出しを更新する。

```swift
// examples を構築（共通ヘルパーとして抽出してもよい）
let lastWord = triggerContext.last
let examples: [(prev: String, next: String)] = lastWord.map { lw in
    db.fetchBigramTop(prev: lw, limit: 5)
        .filter { !InputHandler.particles.contains($0) }  // 助詞を除外
        .map { (prev: lw, next: $0) }
} ?? []

Self.successorLLM.fetch(context: triggerContext, examples: examples) { ... }
```

`db` は `handler.db`（`internal` アクセス）。

**助詞の除外**: `fetchBigramTop` の top5 に「は」「が」等が含まれうる。
プロンプトで「助詞は含めないで」と指示している以上、examples に助詞を渡すのは矛盾するため
`InputHandler.particles` でフィルタする。

**プリセット bi-gram の混在**: `fetchBigramTop` はユーザー学習データとプリセット行（`is_preset=1`）
を区別しない。コールドスタートでも即日 few-shot が機能するため、これはメリットとして受け入れる。

## テスト方針

- `buildPrompt(words:examples:)` の単体テスト
  - `examples` 空 → 傾向セクションなし、既存プロンプトと同一出力（既存の `testBuildPromptJoinsContextPhrase` を新シグネチャに合わせて更新）
  - `examples` 1件以上 → 傾向セクションのヘッダー・カンマ区切り列が正しく出力される
  - `words` と `examples.first?.prev` が一致するケース・しないケース（どちらも出力が崩れないこと）
- LLM 呼び出し本体はオンデバイス依存のため単体テスト対象外

## 実装順序

1. `buildPrompt` の `examples` 引数追加 + プロンプト変更 + 単体テスト
2. `fetch(context:examples:onResult:)` のシグネチャ変更（コンパイルエラーで呼び出し箇所を一括特定）
3. `applySuccessorLLMScheduling` の両ケースに `examples` 構築を追加
4. 動作確認（EventViewerWindow で few-shot あり/なしの候補差分を確認）

## 工数目安

半日以内（`LLMCandidateScorer` の実装パターンを踏襲するため）

## 将来の拡張案（このPLANの対象外）

- `triggerContext` の 1〜2 語前分の bi-gram も examples に追加（複数 prev）
- skip-bigram 上位も examples として注入（話題語→遠位語の傾向）
