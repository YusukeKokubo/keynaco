---
status: implemented
created: 2026-05-25
related_commit: 86c163a
---

# PLAN260525: sessionTextBuffer 導入による Zenzai 左文脈強化

**前提 POC**: [POC260525-left-context-enhancement.md](POC260525-left-context-enhancement.md)

## 実装コミット

| Step | コミット | 概要 |
|------|---------|------|
| 0 | [`5edf2bc`](https://github.com/YusukeKokubo/keynaco/commit/5edf2bc) | content_bigram / POSCommitSequencer 削除 |
| 1 | [`861bd8b`](https://github.com/YusukeKokubo/keynaco/commit/861bd8b) | `sessionTextBuffer` を InputHandler に追加 |
| 2 | [`b66232e`](https://github.com/YusukeKokubo/keynaco/commit/b66232e) | Zenzai 左文脈を `sessionTextBuffer` に差し替え |
| 3 | [`b0b8f08`](https://github.com/YusukeKokubo/keynaco/commit/b0b8f08) | デバッグ state / スナップショット |
| 4 | [`86c163a`](https://github.com/YusukeKokubo/keynaco/commit/86c163a) | テスト・`docs/domain/` 更新 |

## 背景

POC260525 で検証済み。現状の `committedHistory.suffix(5).joined()` は文末（`。` `\n`）のたびにリセットされ leftSideContext="" になる。10 シナリオ中 9 件で fixedEnd が 0→1 に改善することを確認。

本実装では先に content_bigram（noun-bigram）を削除してから sessionTextBuffer を導入する。

## 変更方針

`sessionTextBuffer: String`（上限 50 字・文末でリセットしない）を `InputHandler` に追加し、これを `leftSideContext` の素材として使う。`committedHistory` は `lastCommittedOutput` の参照用として維持する。

---

## Step 0: content_bigram の削除

### 背景

content_bigram は POC260525 以前に「noun-bigram」として導入されたが、実データで全 49 件・count 全 1（実質 0 件）であり、`fetchContentBigram` の閾値 `count >= 2` を満たすレコードが存在しない。機能していないため削除する。

### 削除後も残すもの

- **LLMPOSClassifier**・**history テーブルの pos/pos_tag/lemma/pos_retry 列**：history の POS 更新（ひらがな優先の品詞フィルタ等）に引き続き必要
- **ひらがな優先設定画面**：動作継続（stopWords の移動のみ）

### 変更ファイル

| ファイル | 変更内容 |
|---------|---------|
| `Core/Sources/Core/DatabaseManager.swift` | content_bigram の CREATE TABLE・INDEX・GC エントリを削除。DROP TABLE マイグレーションを追加 |
| `Core/Sources/Core/DatabaseManager+Ngram.swift` | **ファイル丸ごと削除** |
| `Core/Sources/Core/POSCommitSequencer.swift` | **ファイル丸ごと削除** |
| `keynaco/InputController+LLM.swift` | `posCommitSequencer` 静的変数・`schedulePOSClassification` を削除し、LLMPOSClassifier 直呼び出しに置き換え |
| `Core/Sources/Core/InputHandler.swift` | `lastConfirmedContentWordOutput` プロパティ削除 |
| `Core/Sources/Core/InputHandler+Candidates.swift` | `fetchContentBigram` 呼び出しブロック削除 |
| `keynaco/Settings/NounBigramViewController.swift` | **ファイル丸ごと削除** |
| `keynaco/Settings/SettingsWindowController.swift` | NounBigramViewController タブ削除 |
| `keynaco/Settings/HiraganaPreferredViewController.swift` | `POSCommitSequencer.stopWords` 参照を独立定数に置き換え |
| `keynaco/Debug/DebugSocketServer.swift` | `lastConfirmedContentWordOutput` 出力・noun_bigram 関連コマンド削除 |
| `keynaco/Debug/DebugSocketServer+Commands.swift` | `handleSeedNounBigram` / `handleQueryNounBigram` / `set_last_noun` / contentWordState 削除 |
| `Core/Sources/CoreTests/ContentBigramTests.swift` | **ファイル丸ごと削除** |
| `Core/Sources/CoreTests/POSCommitSequencerTests.swift` | **ファイル丸ごと削除** |
| `Core/Sources/CoreTests/InputHandlerCandidatesTests.swift` | noun-bigram 依存テスト（testNoDuplicates…・予測セクションテスト）を削除 |
| `Core/Sources/CoreTests/InputHandlerTestCase.swift` | `seedContentBigram()` ヘルパー削除 |

### 詳細: schedulePOSClassification の置き換え

POSCommitSequencer は「POS 解決後に確定順で content_bigram を記録する」ためのキューだった。content_bigram 削除後は順序保証が不要になるため、LLMPOSClassifier を直接呼べばよい。

```swift
// 変更前（InputController+LLM.swift）
private static let posCommitSequencer = POSCommitSequencer(
    db: DatabaseManager.shared, classifier: posClassifier)

func schedulePOSClassification(output: String, reading: String, context: String? = nil) {
    Self.posCommitSequencer.commit(output: output, reading: reading, context: context,
        contentWordState: POSCommitSequencer.ContentWordState(...))
}

// 変更後
func schedulePOSClassification(output: String, reading: String, context: String? = nil) {
    Self.posClassifier.enqueue(output: output, context: context) { classifiedOutput, pos, posTag, posRetry, lemma in
        DatabaseManager.shared.updatePOS(output: classifiedOutput, pos: pos,
            posTag: posTag, lemma: lemma, posRetry: posRetry)
    }
}
```

### 詳細: stopWords の移動

`POSCommitSequencer.stopWords` は `HiraganaPreferredViewController` で「ひらがな優先」組み込み固定語の表示に使っていた。実装では [`Core/Sources/Core/HiraganaPreferredBuiltins.swift`](../Core/Sources/Core/HiraganaPreferredBuiltins.swift) に移し、`isHiraganaPreferred` も組み込み固定語を参照する。

### DB マイグレーション

既存の `history.db` から content_bigram テーブルを DROP するマイグレーションを追加する。`DatabaseManager.swift` のマイグレーション連番に従って追加。

```sql
DROP TABLE IF EXISTS content_bigram;
```

---

## Step 1〜4 の変更ファイル一覧

> `keynaco/InputController+LLM.swift` は Step 0 でも変更する。Step 0 完了後に Step 2 を適用すること。

| ファイル | Step | 変更内容 |
|---------|------|---------|
| `Core/Sources/Core/InputHandler.swift` | 1 | `sessionTextBuffer` プロパティ追加・`appendToSessionBuffer` 実装・`commitText` から呼び出し・リセット箇所追加 |
| `keynaco/InputController+LLM.swift` | 2 | `resolvedLLMDocumentContextPrefix` で `committedHistory.suffix(5).joined()` → `sessionTextBuffer` に差し替え（Step 0 とは別メソッド） |
| `Core/Sources/Core/InputHandler+Snapshot.swift` | 3 | snapshot に `sessionTextBuffer` を追加（DEBUG 用） |
| `Core/Sources/CoreTests/InputHandlerHistoryTests.swift` | 4 | sessionTextBuffer のテスト追加 |
| `Core/Sources/CoreTests/ZenzaiLeftContextTests.swift` | 4 | 文末後も文脈が残ることを確認するテスト追加 |

---

## Step 1: InputHandler.swift に sessionTextBuffer を追加

### 追加プロパティ

`committedHistory` の近くに追加する（L110 付近）：

```swift
public var sessionTextBuffer: String = ""
```

### appendToSessionBuffer の実装

`pushCommitted` の直後に定義する：

```swift
public mutating func appendToSessionBuffer(_ text: String) {
    guard !InputHandler.readingPunctuations.contains(text) else { return }
    sessionTextBuffer += text
    if sessionTextBuffer.count > 50 {
        sessionTextBuffer = String(sessionTextBuffer.suffix(50))
    }
}
```

`sentenceTerminators`（`。`等）は**リセットせず追記する**（これが現状との最大の差）。  
`readingPunctuations`（`、`等）はスキップ（文脈として有用でないため）。

### commitText からの呼び出し

`pushCommitted(text)` の直後に呼ぶ：

```swift
// InputHandler.swift の commitText 内
pushCommitted(text)
appendToSessionBuffer(text)   // ← 追加
client.insertText(text)
```

### リセット箇所

`committedHistory.removeAll()` している 3 箇所に `sessionTextBuffer = ""` を追加する：

| 箇所 | 条件 | 理由 |
|------|------|------|
| L340（ASCII モード中の Enter） | ASCII Enter 確定 | 文脈の連続性が切れる |
| L368（組成なし Enter） | 改行・送信 | 新しい入力フィールド開始の可能性 |
| InputController.swift L106（activateServer） | アプリ切り替え | 別アプリのコンテキストが混入しないように |

**注意**: InputController.swift の変更は `handler.sessionTextBuffer = ""` の形になる。

---

## Step 2: InputController+LLM.swift の差し替え

`resolvedLLMDocumentContextPrefix` 内の `historyJoined` を `sessionTextBuffer` に変更する：

```swift
// 変更前
let historyJoined = handler.committedHistory.suffix(5).joined()

// 変更後
let historyJoined = handler.sessionTextBuffer
```

それ以外のロジック（IMK の before と結合する部分）は変更しない。

---

## Step 3: InputHandler+Snapshot.swift にデバッグ用フィールド追加

`InputHandlerSnapshot` の `committedHistory` の隣に `sessionTextBuffer` を追加する。デバッグソケットでの検証に使う：

```swift
// snapshot() の戻り値に追加
sessionTextBuffer: sessionTextBuffer,
```

`InputHandlerSnapshot` 構造体と `DebugSocketServer` のシリアライズにも追加が必要かどうかは `InputHandlerSnapshot` の定義を確認してから判断する。

---

## Step 4: テスト

### InputHandlerHistoryTests.swift に追加するテスト

```swift
// sessionTextBuffer は文末でリセットされない
func testSessionTextBufferNotResetBySentenceTerminator() {
    // 語を確定 → 文末確定 → buffer が残っていること
}

// sessionTextBuffer は 50 字で切り詰められる
func testSessionTextBufferTruncatesAt50() { ... }

// activateServer 相当のリセットで sessionTextBuffer がクリアされること
// → InputController レイヤーなので Core のテストでは committedHistory.removeAll() 相当の直接リセットで確認

// 読点（、）は追記されない
func testSessionTextBufferSkipsReadingPunctuations() { ... }
```

### ZenzaiLeftContextTests.swift に追加するテスト

```swift
// 文末後に sessionTextBuffer が leftSideContext として残ること
func testSessionBufferPersistsAcrossSentenceBoundary() {
    // 語を確定 → 文末（sentenceTerminator）を確定 → 次の変換で leftSideContext が空でないこと
    // ※ InputController の resolvedLLMDocumentContextPrefix は Core 層からテストできないため、
    //    sessionTextBuffer が残っていることを直接アサートする
}
```

---

## 実装順序

0. **Step 0**（content_bigram 削除）→ `cd Core && swift test` — 完了（`5edf2bc`）
1. **Step 1**（InputHandler.swift に sessionTextBuffer 追加）→ `cd Core && swift test` — 完了（`861bd8b`）
2. **Step 2**（InputController+LLM.swift 差し替え）— 完了（`b66232e`）
3. **Step 3**（Snapshot にフィールド追加）— 完了（`b0b8f08`）。デプロイ後デバッグソケットで `sessionTextBuffer` を確認
4. **Step 4**（テスト追加）→ `cd Core && swift test` — 完了（`86c163a`）
5. `/keynaco-ime-sandbox` で POC260525 の 10 シナリオを再実行し改善件数を確認 — 未実施（任意）

## 検証方法（実装後）

`/keynaco-ime-sandbox` で以下を確認する：

```python
# 文末後も sessionTextBuffer が残ること
send({"reset": True})
# 語を確定（type_string + enter で入力）
send({"type_string": "houkoku", "then": "space"})
send({"key": "enter"})  # 候補選択
# 文末確定（現状では committedHistory がリセットされる）
# → sessionTextBuffer には "報告" が残っているはず
r = send({"state": True, "fields": ["sessionTextBuffer", "committedHistory"]})
assert r["sessionTextBuffer"] != ""
```

また POC260525 の 10 シナリオを再実行し、実際の実装での改善件数を確認する。
