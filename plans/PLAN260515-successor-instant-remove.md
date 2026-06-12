# PLAN260515: Successor モード「確定直後即時表示」廃止

## 背景・目的

現在の Successor モードには確定直後に候補ウィンドウを出す2つのパスがある。

1. **`particlesOnly` パス** — N-gram なし・名詞末尾のとき格助詞をすぐ表示
2. **`successorImmediateThreshold` パス** — 高信頼 bigram のときすぐ表示

どちらもユーザーが何もキーを押していない状態で候補ウィンドウが割り込む体験になっており、IME の基本原則「ユーザーの入力に対して補完する」に反している。

**目標:** 候補ウィンドウは常にユーザーが1文字タイプしたときに初めて表示する。

## 現状の分岐

```
suggestSuccessors() 呼び出し
├── predictTop.isEmpty（N-gram なし）
│   └── particlesOnly → .show(格助詞) ← 廃止
├── topCount >= successorImmediateThreshold（高信頼）
│   └── .show(candidates) ← 廃止
└── それ以外
    └── pendingSuccessorCandidates に積んで .dismiss ← これだけ残す
```

## 変更方針

### `suggestSuccessors()` の統一

`predictTop.isEmpty` / `topCount >= successorImmediateThreshold` の両ブランチを削除し、常に `pendingSuccessorCandidates` に積んで `.dismiss` を返す。候補が空のときは従来どおりモード解除 + `.dismiss`。

- `successorLLMTrigger = .particlesOnly(...)` の設定も削除（`pendingLowConfidence` 系に統一）
- `successorLLMBaseCandidates` の設定も削除

### 格助詞 fast-path との衝突（重要）

現状、格助詞 fast-path は **`pendingSuccessorCandidates.isEmpty` のときだけ**走る（`handleSuccessorModeKey` L.157）。格助詞を pending に積むと、1打目で fast-path がスキップされ、N-gram 読み前方一致マージ側（`romajiToInitialKana` を使う）に落ちる。しかし `romajiToInitialKana["h"]` は「は・へ」を含まないため、**格助詞が1打目で表示されなくなる**。

**対策 B を採用:** 1打目の pending マージ処理（`handleSuccessorModeKey` L.175〜）で、`romajiToInitialKana` に加えて `particleRomajiMap` でも pending 候補をフィルタする。

```swift
// 既存: romajiToInitialKana[char] で読み前方一致の候補を DB から引く
// 追加: particleRomajiMap[char] にヒットする pending 候補も merged に追加
let particleMatches = (InputHandler.particleRomajiMap[char] ?? [])
    .filter { pendingSuccessorCandidates.contains($0) }
// merged に追加（重複は seen セットで除外）
```

これにより格助詞 fast-path（`pendingSuccessorCandidates.isEmpty` ガード）は**不要になるため削除**し、1打目の統一マージロジックに寄せる。

### 不要になるコード

| 削除対象 | 場所 |
|---------|------|
| `suggestSuccessors()` 内の `particlesOnly` / 即時表示ブランチ | `InputHandler+SuccessorMode.swift` |
| 格助詞 fast-path 分岐（`pendingSuccessorCandidates.isEmpty` ガード） | `InputHandler+SuccessorMode.swift` L.154〜172 |
| `successorLLMBaseCandidates` フィールドと関連ロジック | `InputHandler.swift`, `InputHandler+SuccessorMode.swift`, `DebugSocketServer.swift` |
| `SuccessorLLMTrigger.particlesOnly` ケース | `InputHandler.swift`, `InputController+LLM.swift` |

**残すもの:**

- `LearningThresholds.successorImmediateThreshold` 定数 — `DatabaseManager.swift` のプリセット bigram 初期 count に使用しているため**定数自体は削除しない**。`suggestSuccessors()` 内の参照のみ削除。
- 1打目の pending マージ処理全体（`handleSuccessorModeKey` L.175〜）— 格助詞対応を追加したうえで維持。

## 影響範囲

- `Core/Sources/Core/InputHandler+SuccessorMode.swift`（主要変更）
- `Core/Sources/Core/InputHandler.swift`（フィールド削除）
- `keynaco/InputController+LLM.swift`（`SuccessorLLMTrigger.particlesOnly` ケース削除）
- `keynaco/Debug/DebugSocketServer.swift`（`successorLLMBaseCandidates` 参照削除）
- `Core/Sources/CoreTests/`（`particlesOnly` / 即時表示に依存するテストの修正）
- `docs/domain/glossary.md` / `architecture.md`（即時表示モード・`successorLLMBaseCandidates` の記述削除）

## 確認観点

- 確定直後にキーを押さない限り候補ウィンドウが出ないこと
- 格助詞（「は」「が」「を」等）が1打目で正しく表示されること
- N-gram が蓄積された語の後続候補が1打目で表示されること
- Escape / Backspace でモード解除が正常に動くこと
- `successorImmediateThreshold` 定数が DB 初期化で引き続き機能すること
