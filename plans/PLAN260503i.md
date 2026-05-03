# LLMMisconversionChecker への few-shot 注入 ✅ 実装完了（2026-05-03）

## 目的

`LLMMisconversionChecker` が現状「テキストだけ」を LLM に渡すため、
ユーザー固有の専門用語・ドメイン語彙を誤変換として誤検出（false positive）しやすい。
直近の確定語リストを「このユーザーが使う語」として渡し、LLM が見慣れた語を誤りと判定しにくくする。

## Scorer・Successor との違い

| | Scorer / Successor | MisconversionChecker |
|---|---|---|
| few-shot の目的 | ユーザーの語彙傾向を **積極的に活かす** | ユーザー固有語を **誤検出させない** |
| データソース | DB から bi-gram 上位を fetch | `committedHistory` をそのまま使う（DB fetch 不要） |
| 形式 | `(prev, next)` ペア | フラットな語リスト |

## 変更箇所

### 1. `LLMMisconversionChecker.check()` のシグネチャ変更

```swift
// before
func check(surroundingPrefix: String)

// after
func check(surroundingPrefix: String, recentWords: [String])
```

`recentWords` は空のときは従来どおりのプロンプトにフォールバック。

**スナップショット**: `recentWords` は `check()` 呼び出し時点の配列をクロージャに閉じ込める。
500ms デバウンス中に履歴が変わっても再取得しない（`surroundingPrefix` と文脈がズレるため）。
`check()` → `debounceTask` クロージャ → `runLLMCheck(text:recentWords:)` の全段で同一スナップショットを引き回す。
`runLLMCheck` も `private func runLLMCheck(text: String, recentWords: [String])` に変更し、
`buildPrompt(text:recentWords:)` へ渡す。

### 2. `LLMMisconversionChecker.buildPrompt()` の変更

```swift
// before（private）
private static func buildPrompt(text: String) -> String

// after（internal に昇格してテスト可能にする）
internal static func buildPrompt(text: String, recentWords: [String]) -> String
```

プロンプト構造（`recentWords` が空でないときのみ冒頭セクションを挿入）:

```
【このユーザーが使う語の例】
会議、資料、議事録、作成、報告

次の日本語テキストに誤変換や不自然な表現があれば、箇所と修正案を指摘してください。
問題がなければ「OK」とだけ答えてください。
〜テキスト〜
```

語リストは `recentWords.joined(separator: "、")` で1行にまとめる。

### 3. `InputController.scheduleMisconversionCheck()` の変更

```swift
// before
private func scheduleMisconversionCheck(adapter: IMKTextInputAdapter) {
    let prefix = adapter.surroundingText(maxLength: 200).prefix
    Self.misconversionChecker.check(surroundingPrefix: prefix)
}

// after
private func scheduleMisconversionCheck(adapter: IMKTextInputAdapter) {
    let prefix = adapter.surroundingText(maxLength: 200).prefix
    let recentWords = Array(handler.committedHistory.suffix(5))
    Self.misconversionChecker.check(surroundingPrefix: prefix, recentWords: recentWords)
}
```

DB fetch は不要。`handler.committedHistory` を直接使う。

## テスト方針

- `buildPrompt(text:recentWords:)` を `internal` に変更し `@testable import` でテスト
- テストケース
  - `recentWords` 空 → 語リストセクションなし、既存プロンプトと同一出力
  - `recentWords` 1件以上 → セクションヘッダーとカンマ区切りリストが正しく出力される
  - `recentWords` 5件（上限）で正しく結合される
- LLM 呼び出し本体はオンデバイス依存のため単体テスト対象外

## 実装順序

1. `buildPrompt` を `internal` に変更 + `recentWords` 引数追加 + プロンプト変更 + 単体テスト
2. `check(surroundingPrefix:recentWords:)` のシグネチャ変更（`runLLMCheck` への引き渡しも更新）
3. `scheduleMisconversionCheck` で `committedHistory.suffix(5)` を渡す
4. 動作確認（F4 で false positive が減ることを EventViewerWindow でキャプチャ確認）

## 工数目安

2〜3時間（DB fetch なし・Scorer/Successor より単純）
