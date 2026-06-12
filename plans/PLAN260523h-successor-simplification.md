# Step 3: Successor サブ経路の簡素化

作成: 2026-05-23  
親計画: [`PLAN260523e-ime-simplification-phase2.md`](PLAN260523e-ime-simplification-phase2.md)

## ゴール

Successor モード **本体**（名詞確定 → `pendingSuccessorCandidates` 保持 → 1 打目で表示 → 確定 → 連鎖）は維持し、以下 3 つの **上乗せ経路** を削除して 1 本化する。

| 削除する経路 | 現状の役割 |
|--------------|------------|
| A. `expandSuccessorPrefixes` / `splitSurfaceAtParticles` | 長い bi-gram を助詞境界で prefix 分割 |
| B. `buildPendingCandidateList` | `pendingRomaji` 1 文字時に Successor 候補を即表示 |
| C. 2 打目以降 Romaji 絞り込み | `successorRomajiBuffer` / `successorActiveCandidates` による段階絞り込み |

**残す経路（唯一の Successor フロー）**:

```
名詞確定 → suggestSuccessors() → pending 保持（ウィンドウ非表示）
  → 1 打目（ローマ字 1 文字）→ DB 再クエリ + pending merge + 格助詞マッチ
  → .show（最大 5 件）
  → Space/Enter で確定 → suggestSuccessors() 連鎖
  → 1 打目不一致 → 1 打目を通常入力に流してモード解除
```

## 背景

[`PLAN260523c-ime-feature-audit.md`](PLAN260523c-ime-feature-audit.md) では A を維持（「からの」→「から」ケース）。本 Step では **複雑さ対効果** で削除を再判断。

- A は [`ideas/IDEA260520.md`](../ideas/IDEA260520.md) の表示時パッチ。形態素解析なしの助詞ヒューリスティックで、根本原因（複合 bi-gram 蓄積）は [`ideas/IDEA260520b.md`](../ideas/IDEA260520b.md) 側
- B と C は [`PLAN260428-successor-pending-romaji.md`](PLAN260428-successor-pending-romaji.md) 以降積み上がった **3 層の先読み/絞り込み**。同一モード内で状態フィールドが重複（`pendingSuccessorCandidates` vs `successorActiveCandidates`）

## A. prefix 展開削除

### 削除対象

| 操作 | ファイル |
|------|----------|
| 関数削除 | `InputHandler+SuccessorMode.swift` — `splitSurfaceAtParticles` / `expandSuccessorPrefixes` |
| 呼び出し削除 | `handleSuccessorMode` default 分岐 — `expandSuccessorPrefixes(candidates: filtered)` を **`filtered` そのまま** に |
| ファイル削除 | `Core/Sources/CoreTests/InputHandlerSuccessorPrefixTests.swift` |

### 許容する退化

- bi-gram に「からの」「会議に出席する」等が蓄積されている場合、**部分 prefix（「から」「会議」）は出なくなる**
- 将来 [`ideas/IDEA260520b.md`](../ideas/IDEA260520b.md) で学習側分割を入れた場合に再評価

### sandbox 回帰（削除前に記録推奨）

[`PLAN260523c-ime-feature-audit.md`](PLAN260523c-ime-feature-audit.md) ケース: prev→「からの」bi-gram 登録後 `k` → `['からの', 'から']`  
削除後: `['からの']` のみ（**期待する退化**）

---

## B. `buildPendingCandidateList` 削除

### 削除対象

| 操作 | ファイル |
|------|----------|
| 関数削除 | `InputHandler+Candidates.swift` — `buildPendingCandidateList` |
| 分岐削除 | `InputHandler+NormalInput.swift` — `handleRomaji` 内 `hasPendingPreview` → `buildPendingCandidateList` 呼び出し |
| ファイル削除 | `Core/Sources/CoreTests/InputHandlerPendingPreviewTests.swift` |
| テスト整理 | `InputHandlerVirtualContextTests.swift` — `buildPendingCandidateList` 直接呼び出しケース削除 |
| コメント整理 | `InputController.swift` — handle 前 `virtualHistoryPrefix` セット理由の pending 言及 |

### 挙動変化

| 操作 | 削除前 | 削除後 |
|------|--------|--------|
| 名詞確定直後 `k` 1 文字 | 即 `.show`（先読み Successor） | 通常組成（`k` pending）。Successor は **確定後の suggestSuccessors 経由のみ** |
| `n` 1 文字 | 除外（`ん` 曖昧） | 同左（通常組成） |

名詞確定 → 助詞候補を出したい場合: **従来の Successor 1 打目待ち**（ウィンドウは出ないが 1 打目で表示）が唯一の経路になる。

---

## C. 2 打目以降 Romaji 絞り込み削除

### 削除対象

| 操作 | ファイル |
|------|----------|
| フィールド削除 | `InputHandler.swift` — `successorActiveCandidates` / `successorKanaPrefix` / `successorRomajiBuffer` / `successorSubsequentKeys` |
| ロジック削除 | `InputHandler+SuccessorMode.swift` — `handleSuccessorMode` default 分岐の `else if first != nil, !successorActiveCandidates.isEmpty` ブロック全体（208 行目付近〜） |
| リセット整理 | 各所の `successorActiveCandidates = []; ...` 4 フィールドクリアを削除 |
| テスト更新 | `InputHandlerSuccessorTests.swift` — 2 打目絞り込み系テスト削除・期待値更新 |
| スナップショット | `InputHandlerSnapshot.swift` / `+Snapshot.swift` — 削除フィールドがあれば除去 |

### 1 打目不一致時の挙動（維持）

```swift
// 既存: first を通常 handle に流してから default キーを処理
if let first {
    _ = handle(keyCode: first.keyCode, ...)
}
return handle(keyCode: keyCode, ...)
```

2 打目以降の `capturedSubsequentKeys` 再生ループも **C 削除に伴い不要**（1 打目バッファ `successorFirstChar` のみ残す）。

---

## ドキュメント更新

| ファイル | 変更 |
|----------|------|
| `docs/domain/architecture.md` | Successor 節から pending 先読み・prefix 展開・2 打目絞り込みを削除。フローを 1 本化 |
| `docs/domain/glossary.md` | `expandSuccessorPrefixes` / pending 先読み / `successorActiveCandidates` 等の節削除 |
| `docs/domain/scenarios.md` | S-XX pending 先読みシナリオ削除 or 更新 |
| `docs/domain/states.md` | Successor 状態遷移を簡素化 |

## 検証

```bash
cd Core && swift test --filter Successor
cd Core && swift test --filter PendingPreview   # ファイル削除後は 0 tests で OK
cd Core && swift test --filter SuccessorPrefix  # 同上
```

sandbox 必須ケース:

1. **基本**: `kanji` Space Enter → `k` → bigram 候補 `.show` → Enter 確定 → 連鎖
2. **1 打目不一致**: 名詞確定 → `x`（マッチなし）→ 通常入力に `x` が入る
3. **格助詞 fallback**: bigram 空・名詞末尾 → `h` → `は` 等
4. **退化確認**: 「からの」bi-gram → `k` → `からの` のみ（`から` なし）

## リスク

| リスク | 深刻度 | 備考 |
|--------|--------|------|
| pending 先読み削除で 1 打目早さ低下 | 中 | 確定直後の 1 打目待ちは維持。`k` 時点での即表示のみ失う |
| prefix 展開削除で長 bi-gram 部分採用不可 | 中 | IDEA260520b 未実装間の既知トレードオフ |
| 2 打目絞り込み削除で候補絞り込み不可 | 低 | 1 打目マッチで十分なケースが大半 |

## サブ PR 分割案（任意）

```
PR 3a: expandSuccessorPrefixes 削除（テストファイルごと）
PR 3b: buildPendingCandidateList 削除
PR 3c: 2 打目 Romaji 絞り込み + フィールド削除
PR 3d: docs 一括更新
```

## 完了条件

- [ ] A/B/C 削除完了
- [ ] `InputHandlerSuccessorTests` 更新・パス
- [ ] sandbox 4 ケース記録
- [ ] domain docs 更新
