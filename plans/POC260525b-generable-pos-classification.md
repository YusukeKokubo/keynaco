---
status: abandoned
created: 2026-05-25
related_rejected: H-1
---

# POC260525b: FoundationModels @Generable による品詞分類の構造化出力検証

**結果**: 失敗 → 代替方針確定（[PLAN260525b-candidate-filter-prompt.md](PLAN260525b-candidate-filter-prompt.md)）

## 背景・動機

現在の `LLMPOSClassifier` はプレーンテキスト応答をパースして品詞を判定しているが、以下の問題がある：

- LLM がフォーマットを守らず自然言語の説明文を返すことがある（69件のガベージ pos_tag が DB に残存）
- パース失敗時に `categoryFromTag` の `default: return "other"` が発動し、業務名詞が候補から消える
- 「設定」「申請」「担当者」などよく使う名詞が `other` に大量誤分類されている（全体の59%が `other`）
- 候補表示フィルタ（`pos = 'noun' OR pos LIKE 'proper_noun%'`）が allowlist 方式のため、誤分類のダメージが大きい

FoundationModels の `@Generable` を使った構造化出力（Guided Generation）を使えば、LLM がスキーマに違反するトークンを生成できなくなるためガベージ問題を根本解決できる可能性がある。

## 検証結果

### 試したこと

| アプローチ | 実装 | 結果 |
|-----------|------|------|
| `respond(generating:)` + @Generable enum | `POSResultV2` (String + .anyOf) | **ハング（無応答）** |
| `respond(generating:)` + 最小 @Generable struct | `SmokeTestResult` (フィールド1つ) | **ハング（無応答）** |
| Tool Calling (`struct POSTagTool: Tool`) | `POSToolParameters` @Generable + `respond(to:)` | **ハング（無応答）** |

すべてのケースで `respond` が返らず、エラーも投げない永続的ハング状態となった（45秒タイムアウトで確認）。

### 根本原因

**macOS 26 Beta のシステムバグ（コードの問題ではない）**

- IME Extension（Input Method Extension）は通常アプリより厳しいサンドボックスプロファイルが適用される
- Guided Generation のスキーマ検証は `generatived` / `com.apple.modelcatalog.catalog` への XPC 通信を必要とする
- IME サンドボックスが XPC 通信を拒否（Error 159: Sandbox restriction）
- クライアントプロセスに完了シグナルも例外も届かないまま同期スレッドがデッドロック
- システムログ: `Error Domain=NSCocoaErrorDomain Code=4099 "The connection to service named com.apple.modelcatalog.catalog was invalidated: Connection init failed at lookup with error 159 - Sandbox restriction."`
- Apple Developer Forums でも `LanguageModelSession.respond()` が "resolve も throw もしない" フリーズの報告が複数あり

### workaround の有無

**なし**。コードレベルでの回避策は存在しない。OS アップデートを待つか、構造化出力を使わない設計に切り替えるのが唯一の現実的な判断。

## 結論と次の方針

構造化出力 POC は macOS 26 Beta の制約により現時点では実現不可能。
以下の2施策に切り替える（→ [PLAN260525b-candidate-filter-prompt.md](PLAN260525b-candidate-filter-prompt.md)）：

**施策A（即効）: フィルターをブロックリスト方式に変更**
- allowlist (`pos = 'noun' OR pos LIKE 'proper_noun%'`) → blocklist（`particle` / `conjunction` / `interjection` のみ除外）
- LLM 分類結果に関係なく、設定・申請・担当者が即座に候補に出るようになる

**施策B（品質向上）: 既存 `LLMPOSClassifier` のプロンプト改善**
- サ変名詞（設定・申請・同期等）を `noun` に強制する few-shot ルールを追加
- プレーンテキスト `respond(to:)` は動作しているため、プロンプト改善で精度向上できる

## 関連

- [POC260524-zenzai-topic-inference.md](POC260524-zenzai-topic-inference.md) - Zenzai プロモーション検証
- [POC260525-left-context-enhancement.md](POC260525-left-context-enhancement.md) - leftSideContext 強化検証
- [PLAN260525b-candidate-filter-prompt.md](PLAN260525b-candidate-filter-prompt.md) - 次の施策（ブロックリスト + プロンプト改善）
