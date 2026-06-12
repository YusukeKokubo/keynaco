---
status: implemented
created: 2026-05-23
related_commit: 1644f7c
---

# Step 2: `boundary_pref` 削除

親計画: [`PLAN260523e.md`](PLAN260523e.md)

## ゴール

セグメント境界学習テーブル `boundary_pref` と、その読み書きロジックを削除する。セグメントモードは AzooKey `segmentize` + `tryManualBisection` のみで動作させる。

## 背景

- 手動境界調整 or LLM 境界推定成功時に読み分割を DB 保存し、次回 Space 時に優先する機能
- 実 DB 分析（[`ideas/IDEA260513.md`](../ideas/IDEA260513.md)）: **1 件のみ** 蓄積。実質未使用
- `enterSegmentMode` の分岐・`penalizeAll` 連動・GC が複雑さに見合う効果を出していない

## 削除対象

| 操作 | ファイル |
|------|----------|
| ファイル削除 | `Core/Sources/Core/DatabaseManager+Boundary.swift` |
| ファイル削除 | `Core/Sources/CoreTests/InputHandlerSegmentBoundaryPrefTests.swift` |
| テーブル定義削除 | `Core/Sources/Core/DatabaseManager.swift` — `CREATE TABLE boundary_pref` |
| GC 削除 | `DatabaseManager.swift` — `boundary_pref` の `DELETE WHERE used_at < ?` |
| penalize 整理 | `DatabaseManager.swift` — `penalizeAll` 内の `DELETE FROM boundary_pref` を削除 |
| 読み取り分岐削除 | `InputHandler+SegmentMode.swift` — `enterSegmentMode` 先頭の `fetchBoundaryPref` ブロック（`if let stored = db.fetchBoundaryPref...` 全体） |
| 書き込み削除 | `InputHandler+SegmentMode.swift` — `doConfirmSegments` 内 `db.saveBoundaryPref(...)` |
| 手動調整フラグ | `Segment.isManuallyAdjusted` は **残してよい**（history ブースト記録に使用中）。boundary 保存だけ外す |
| テスト削除 | `DatabaseManagerTests.swift` — `boundary_pref` / `penalizeAll` の boundary 関連ケース |

## 残すもの

- セグメントモード全体（`enterSegmentMode` / Shift+矢印 / `doConfirmSegments`）
- `tryManualBisection`（`PLAN260523c` 維持判断）
- `penalizeAll` の **history** ペナルティ（Backspace 訂正シグナル）
- 手動境界調整時の `recordPrefixes` 二重記録（`isManuallyAdjusted` ブースト）

## 既存 DB の扱い

- マイグレーション不要: 起動時 `DROP` は他の廃止テーブルと同様、**次回スキーマ更新時にテーブル作成を止めるだけ** でよい
- 既存 `boundary_pref` 行は読まれなくなる（孤児データ）。任意で `DROP TABLE IF EXISTS boundary_pref` を `DatabaseManager` 初期化に追加してもよい（他廃止テーブルと同パターン）

## ドキュメント更新

| ファイル | 変更 |
|----------|------|
| `docs/domain/glossary.md` | `boundary_pref` 節削除。`SegmentState.llmWholeText` 等の stale 記述があれば整理 |
| `docs/domain/architecture.md` | DatabaseManager 5 テーブル → 4 テーブル。`boundary_pref` 言及削除 |

## 検証

```bash
cd Core && swift test --filter InputHandlerSegment
cd Core && swift test --filter DatabaseManager
```

sandbox:

- `setteigamen` → Space → セグメントモード（`tryManualBisection` / AzooKey 分割）が従来どおり
- 手動 Shift+←/→ 調整 → Enter 確定が動作（boundary 未保存でも退化なし）

## リスク

**低** — 実データ上ほぼ未使用。ユーザーが境界を手動調整しても **次回同じ読みで自動復元されなくなる** のみ（AzooKey デフォルト分割に戻る）。

## 完了条件

- [ ] `boundary_pref` 関連コード削除
- [ ] テスト更新・パス
- [ ] glossary / architecture 更新
