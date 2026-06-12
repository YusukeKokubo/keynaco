# PLAN260506c: コードベース リファクタリング

## 目的

コードベース全体（Core・App・テスト）を「AIが読みやすい適切なサイズ」に分割・整理する。
目標：原則 1ファイル ≤ 400行（理由付きで ~460行まで許容）、責務の明確化、重複コード除去。
各 Step はそれ単独でマージ可能な単位にすることを推奨。

---

## 現状の問題

| ファイル | 行数 | 主な問題 |
|---------|------|---------|
| `Core/.../DatabaseManager.swift` | 1028 | 6テーブル分の責務が混在、N-gramクエリが3回重複 |
| `keynaco/InputController.swift` | 607 | 状態リセットブロックが2箇所に重複、LLMスケジューリングが肥大化 |
| `Core/.../InputHandler+Candidates.swift` | 513 | `buildCandidateList()`が126行、入力ハンドラも混在 |
| `Core/.../InputHandler+SegmentMode.swift` | 462 | `recordPrefixes`重複呼び出し（バグ）、`resizeFocusedSegment`が68行 |
| `Core/.../InputHandler.swift` | 424 | `handle()`が103行のdispatcher兼初期化 |
| `CoreTests/InputHandlerCandidatesTests.swift` | 718 | pending先読み・Zenzai等が混在 |
| `CoreTests/InputHandlerSegmentTests.swift` | 610 | boundary_pref LLMテストが末尾130行に混在 |
| `CoreTests/InputHandlerCompositionTests.swift` | 596 | 句読点・Fキーテストが混在 |

---

## Step 1: DatabaseManager 分割（最大効果）

### 分割先ファイル

| ファイル | 担当 | 推定行数 |
|---------|------|---------|
| `DatabaseManager.swift` | init / 接続 / スキーマ / マイグレーション / GC / penalizeAll / プリセット投入 | ~350行 |
| `DatabaseManager+History.swift` | record / fetchHistoryScored / fetchHistoryScoredMerged / fetchAllHistory | ~150行 |
| `DatabaseManager+Ngram.swift` | fetchBigram / fetchTrigram / fetchSkipBigram / record系 / fetchBigramTop / fetchBigramInList / fetchBigramTopCount / fetchAllBigram | ~250行 |
| `DatabaseManager+UserDict.swift` | fetchUserDict / insertUserDict / deleteUserDict / fetchAllUserDict | ~100行 |
| `DatabaseManager+Boundary.swift` | saveBoundaryPref / fetchBoundaryPref / recordPrefixes | ~100行 |

### N-gram 重複クエリの統合

fetchBigram / fetchTrigram / fetchSkipBigram の3メソッドはほぼ同一構造。
`DatabaseManager+Ngram.swift` 内で共通 `private` ヘルパー `fetchNgramOutputs(table:prev:reading:limit:)` に統合する。
同ファイル内の `private` に閉じるため、`fileprivate` / `internal` の変更は不要。
ただしスキップ bi-gram は `prev` の意味（前語でなく近傍内容語）が異なる可能性があるため、
統合できるか実際の SQL を確認してから判断し、差異があれば別ヘルパーにする。

---

## Step 2: InputHandler+Candidates 分割

### ファイル分割

| ファイル | 担当 | 推定行数 |
|---------|------|---------|
| `InputHandler+Candidates.swift` | buildCandidateList / fetchAzooKeyCandidates / section計算 / buildPendingCandidateList | ~280行 |
| `InputHandler+NormalInput.swift` | handleRomaji / handleSpace / handleEnter / handleBackspace / handleZSequence / handlePunctuation / handleBracketChar / handleFunctionKey | ~250行 |

### buildCandidateList() の内部整理（126行 → private メソッド委譲）

```
collectCandidateSources()   → AzooKey・history・userDict・bigram 取得
assembleCandidateList()     → 優先順位に従ってリスト組み立て
appendSpecialCandidates()   → 数値・日時候補追加
```

> **注意**: ファイル分割でシグネチャや型の参照元が変わり、コンパイルエラーが一時的に出やすい。
> 分割直後に必ず `swift test` を通してから次へ進む（他のステップも同様）。
> extension 間をまたいで参照する internal メソッドは `private` のままでよいが、
> 同一ファイル内のみを前提にした `private` が別ファイルに移動する場合は `internal` への緩和が必要になるので一度確認する。

---

## Step 3: InputController 整理

### 重複リセットの除去

`activateServer()` と `commitComposition()` で同じ ~15行の状態リセットブロックが重複。
`resetAuxiliaryState()` private メソッドに統一する。

### ファイル分割

| ファイル | 担当 | 推定行数 |
|---------|------|---------|
| `InputController.swift` | クラス定義 / handle() / activate-deactivate / commitComposition / candidate操作 | ~350行 |
| `InputController+LLM.swift` | applySuccessorLLMScheduling / applySegmentLLMScheduling / resolvedLLMDocumentContextPrefix / misconversionChecker | ~250行 |

> **注意**: LLM 系はコールバック・`@MainActor` 制約・`weak self` の弱参照が絡む。
> 移動後も `@MainActor` アノテーションと弱参照キャプチャの構造を変えないこと。

---

## Step 4: InputHandler+SegmentMode 整理

### バグ修正（挙動変更あり）

`doConfirmSegments()` 内の `isManuallyAdjusted` 時に **`recordPrefixes`（385/389/390行）と `recordBigram`（402/404/405行）の両方が同一引数で3回呼ばれている**。
これが意図的な加重（extra boost）なのかバグなのかを先にコードコメント・PR 経緯から確認し、**バグなら両方を1回に修正**する。
学習スコアが変わるため、`SegmentBoundaryTests` で境界学習と bi-gram スコア両方の差分を確認してから進む。
意図的な加重だった場合はコメントで仕様を明記して修正しない。

### resizeFocusedSegment()（68行）の分割

```
resizeFocusedSegment()   → dispatch のみ（~10行）
expandFocusedSegment()   → 拡張ロジック（private）
shrinkFocusedSegment()   → 縮小ロジック（private）
```

分割後: ~380行

---

## Step 5: InputHandler.swift 整理

### handle()（103行）の薄型化

モード判定の序列を維持しつつ、各モードのハンドリングを private メソッドに委譲。
以下の全分岐を漏れなく委譲することで完了とする。

```
handleSuccessorModeKey()       → isSuccessorMode 時
handleBracketModeKey()         → isBracketMode 時
handleSegmentModeKey()         → isSegmentMode 時
handleCandidateVisibleKey()    → 候補ウィンドウ表示中
handleModeSwitch()             → eisu / kana キー
handleAsciiModeKey()           → isAsciiMode 時のパススルー
handleNormalKey()              → 上記以外（既存 handleNormalInput へ委譲）
```

本体の handle() は残った分岐 dispatch のみ（~20行目安）。
分割後: ~350行

---

## Step 6: テスト — InputHandlerTestCase にヘルパー追加

現状93行 → ~220行に拡充。各テストファイルの重複を削減。

### 追加メソッド

```swift
// データセットアップ
func setupBigramChain(_ items: [(prev: String, input: String, output: String)])
func setUpWithConverter(_ converter: AzooKeyConverting)

// 入力シーケンス
func typeAndPress(_ romaji: String, keyCode: UInt16 = KeyCode.space) -> (Bool, CandidateAction)
func confirmWithSelection(_ romaji: String, selectedText: String) -> (Bool, CandidateAction)
func enterSegmentMode(with romaji: String) -> SegmentState?

// アサーション
func assertMarkedText(_ expected: String, _ msg: String = "", file: StaticString = #file, line: UInt = #line)
func assertInserted(_ expected: String, _ msg: String = "", file: StaticString = #file, line: UInt = #line)
func assertSuccessorMode(_ expected: Bool, _ msg: String = "", file: StaticString = #file, line: UInt = #line)
func assertSegmentMode(_ expected: Bool, _ msg: String = "", file: StaticString = #file, line: UInt = #line)
func assertCandidatesContain(_ action: CandidateAction, _ expected: String..., file: StaticString = #file, line: UInt = #line)
func requireSegmentMode(minSegments: Int = 2) -> SegmentState?
```

---

## Step 7: テスト — 大きなファイルの分割

`InputHandlerSegmentTests` のメインは ~460行（境界値の目標超え）だが、
セグメント基本・境界調整・Zenzai LLM を一つのテストクラスに収めておく方が文脈の連続性が高いため許容する。

| 現状ファイル | 行数 | 分割先 | 推定行数 |
|------------|------|--------|---------|
| `InputHandlerCandidatesTests.swift` | 718 | メイン（候補表示・履歴・bigram） | ~380行 |
| | | `InputHandlerPendingPreviewTests.swift`（pendingRomaji先読み 11テスト） | ~200行 |
| `InputHandlerCompositionTests.swift` | 596 | メイン（ローマ字・確定・Escape・Backspace） | ~320行 |
| | | `InputHandlerPunctuationTests.swift`（句読点・括弧・Fキー） | ~280行 |
| `InputHandlerSegmentTests.swift` | 610 | メイン（セグメント基本 + 境界調整） | ~460行 ※許容 |
| | | `InputHandlerSegmentBoundaryPrefTests.swift`（boundary_pref LLM） | ~160行 |

---

## 実装順序

1. Step 1: DatabaseManager 分割 → `swift test`
2. Step 2: InputHandler+Candidates 分割 → `swift test`
3. Step 3: InputController 整理 → `swift test` + `xcodebuild build`
4. Step 4: InputHandler+SegmentMode バグ修正 + 整理 → `swift test`（SegmentBoundaryTests で差分確認）
5. Step 5: InputHandler.swift 整理 → `swift test`
6. Step 6: InputHandlerTestCase ヘルパー追加 → `swift test`
7. Step 7: テストファイル分割 → `swift test`

## 検証方法

- **Core のみ変更**: `cd Core && swift test`
- **App 層を変更した後**: `xcodebuild build -scheme keynaco -configuration Debug`
- **InputController 変更前後**: `xcodebuild test -scheme keynaco -destination "platform=macOS"` でフルテストも推奨

## ドメインドキュメント更新

Step 4 で `recordPrefixes` / `recordBigram` の重複を修正した場合、境界学習と bi-gram スコアの重みが変わる。
- バグ修正（過剰加重の除去）として扱う場合: `glossary.md` の bigram・境界学習の不変条件に「手動調整時の boost は1回」と一文追記する
- 意図的な仕様だった場合: コメントで理由を残し `docs/domain/` は変更不要
