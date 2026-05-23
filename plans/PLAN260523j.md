# IME 簡素化 Phase 3 — 概要・実行順序

作成: 2026-05-23

## 背景

Phase 2（[`PLAN260523e.md`](PLAN260523e.md)）完了後、2026-05-23 の IME 機能棚卸し会話で **残存する削除候補** を再評価した。

会話中に以下は **削除候補から除外**（維持確定）:

| 対象 | 理由 |
|------|------|
| Shift+英字組成（`handleShiftChar` / `handleAsciiWord`） | ASCII モードでは代替不可（混在組成・履歴学習・モード切替コスト） |
| 候補リスト末尾の自動カタカナ行 | F7 は fn 併用が必要で候補ウィンドウ経路の代替にならない |
| F9 / F10 ローマ字確定 | 一般的な IME（macOS 日本語入力等）との F キー挙動互換 |
| z シーケンス / 括弧モード | ユーザー判断で評価対象外 |
| 数字・日時候補 / 設定 UI | 同上 |
| Successor 格助詞 fallback / 右矢印確定 / `isManuallyAdjusted` 二重記録 | 維持（削除計画は作成しない） |

本 Phase 3 は **上記除外後に残った候補** の実装計画。

## Step 一覧

| Step | 計画書 | 内容 | 難度 | 依存 |
|------|--------|------|------|------|
| 1 | [`PLAN260523k.md`](PLAN260523k.md) | dead code 削除（`mostRecentContentWord*`） | 低 | なし |
| 2 | [`PLAN260523m.md`](PLAN260523m.md) | 確定時 shadow segmentize 学習削除 | 中 | なし |
| 3 | [`PLAN260523q.md`](PLAN260523q.md) | domain docs の stale 記述整理 | 低 | Step 1–2 後推奨 |

## 推奨実施順序

```
Step 1 (dead code)
  ∥  Step 2 (shadow segmentize)
    → Step 3 (docs 整理)
```

- Step 1–2 は互いに独立。1 PR にまとめてもよい。
- Step 3 は Phase 2 削除（LLM セグメント・`boundary_pref` 等）の stale 記述も含むため、Step 1–2 完了後にまとめて触るのが効率的。

## スコープ外（本 Phase 3 では触らない）

| 対象 | 理由 |
|------|------|
| F6–F10 変換確定（F9/F10 含む） | 一般 IME との互換 |
| Successor モード本体 / noun-bigram 組成中予測 / 格助詞 fallback | 中核 UX |
| 候補表示中の右矢印確定 | 維持 |
| `isManuallyAdjusted` 二重 `recordPrefixes` | 維持 |
| セグメントモード / `tryManualBisection` | Phase 2 維持判断済み |
| `LLMPOSClassifier` / 履歴 / `penalizeAll` | 学習根幹 |
| Shift+英字組成 / 末尾カタカナ行 | 会話で維持確定 |

## 完了条件（Phase 3 全体）

- [ ] Step 1–2 のコード変更完了
- [ ] `cd Core && swift test` パス
- [ ] `xcodebuild test -scheme keynaco -destination "platform=macOS"` パス
- [ ] Step 3 で `docs/domain/*.md` の stale 記述を整理

## 見積もり（削除 LOC 概算）

| Step | 削除 LOC | 主な削除対象 |
|------|----------|--------------|
| 1 | ~40 | `mostRecentContentWord*` + 関連テスト |
| 2 | ~90 | `doConfirmSelection` 内 Task.detached + テストファイル |
| 3 | — | docs のみ（コード変更なし） |

## 関連

- 前提調査: 2026-05-23 IME 機能棚卸し会話
- Phase 2 完了: [`PLAN260523e.md`](PLAN260523e.md)（`4e3cbd1`–`6d8aec8`）
