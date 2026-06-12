---
status: implemented
created: 2026-05-23
related_commit: 6d8aec8
---

# IME 簡素化 Phase 2 — 概要・実行順序

## 背景

[`PLAN260523c-ime-feature-audit.md`](PLAN260523c-ime-feature-audit.md) / [`PLAN260523d-ime-simplification-phase1.md`](PLAN260523d-ime-simplification-phase1.md) で Phase 1（`LLMSuccessorFetcher` 層削除、`lowHistory` 廃止等）を実施した。

本 Phase 2 は **IME 入力・変換パイプライン** に限定し、前回の機能評価（2026-05-23 会話）で「有益性より削除メリットが大きい」と判断した項目の実装計画をまとめる。

[`PLAN260523c-ime-feature-audit.md`](PLAN260523c-ime-feature-audit.md) では誤変換検出・`expandSuccessorPrefixes` 等を **維持** と判断していたが、本 Phase 2 では **削除・簡素化を再検討** する（理由は各 Step 計画書に記載）。

## スコープ外（本 Phase 2 では触らない）

| 対象 | 理由 |
|------|------|
| z シーケンス | ユーザー判断で考慮不要 |
| 括弧モード（`bracketOptions` 間引き含む） | 同上 |
| `generateDateTimeCandidates` / `generateNumberCandidates` | ユーザー判断で維持（`PLAN260523d` と同様） |
| `LLMCleanser` / 設定 UI 全般 | 設定・履歴メンテ |
| `LLMPOSClassifier` / noun-bigram 本体 | Successor の学習根幹 |
| Successor モード本体（確定後 1 打目待ち → 表示 → 確定） | 中核 UX。サブ経路のみ整理 |
| セグメントモード本体 / `tryManualBisection` | `PLAN260523c` sandbox 確認済み・維持 |

## Step 一覧

| Step | 計画書 | 内容 | 難度 | 依存 |
|------|--------|------|------|------|
| 1 | [`PLAN260523f-misconversion-checker-removal.md`](PLAN260523f-misconversion-checker-removal.md) | `LLMMisconversionChecker` 削除 | 中 | なし |
| 2 | [`PLAN260523g-boundary-pref-removal.md`](PLAN260523g-boundary-pref-removal.md) | `boundary_pref` 削除 | 低 | なし |
| 3 | [`PLAN260523h-successor-simplification.md`](PLAN260523h-successor-simplification.md) | Successor サブ経路の簡素化 | 高 | Step 2 不要。Step 1 と独立 PR 可 |
| 4 | [`PLAN260523i-virtual-history-prefix-removal.md`](PLAN260523i-virtual-history-prefix-removal.md) | `virtualHistoryPrefix` 廃止 | 中 | **Step 3 後推奨**（pending 先読み削除で handle 前タイミングの理由が減る） |

## 推奨実施順序

```
Step 1 (誤変換検出削除)
  ∥  Step 2 (boundary_pref 削除)   ← 並行 PR 可
    → Step 3 (Successor 簡素化)
      → Step 4 (virtualHistory 廃止)
```

- Step 1・2 は互いに独立。どちらから着手してもよい。
- Step 3 は diff 最大。1 PR にまとめるか、以下のサブ PR に分割してもよい:
  1. `expandSuccessorPrefixes` 削除
  2. `buildPendingCandidateList` 削除
  3. 2 打目以降 Romaji 絞り込み削除
- Step 4 は Step 3 完了後が望ましい（`InputController` の handle 前 `virtualHistoryPrefix` セットの主理由の一つが pending 先読みのため）。

## 完了条件（Phase 2 全体）

- [ ] Step 1–4 のコード変更完了
- [ ] `cd Core && swift test` パス
- [ ] `xcodebuild test -scheme keynaco -destination "platform=macOS"` パス
- [ ] 該当 `docs/domain/*.md` と `CLAUDE.md` を各 Step で更新
- [ ] `/keynaco-ime-sandbox` で Successor 基本フロー回帰（名詞確定 → 1 打目 → 候補表示 → 確定）

## 見積もり（削除 LOC 概算）

| Step | 削除 LOC | 主な削除対象 |
|------|----------|--------------|
| 1 | ~250 | `LLMMisconversionChecker.swift`、AppDelegate 通知 UI |
| 2 | ~120 | `DatabaseManager+Boundary.swift`、segment 読み取り分岐 |
| 3 | ~200–280 | prefix 展開・pending 先読み・多打鍵絞り込み |
| 4 | ~80 | `VirtualHistoryExtractor`、InputController タイミング分岐 |

## 関連

- 前提調査: [`PLAN260523c-ime-feature-audit.md`](PLAN260523c-ime-feature-audit.md)
- Phase 1 実装: [`PLAN260523d-ime-simplification-phase1.md`](PLAN260523d-ime-simplification-phase1.md)
- prefix 展開の代替（将来）: [`ideas/IDEA260520b.md`](../ideas/IDEA260520b.md)（学習時分割記録）
