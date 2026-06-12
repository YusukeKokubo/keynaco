# Step 3: domain docs の stale 記述整理

作成: 2026-05-23  
親計画: [`PLAN260523j-ime-simplification-phase3.md`](PLAN260523j-ime-simplification-phase3.md)（Phase 3 Step 3）

## ゴール

Phase 2 および Phase 3 Step 1–2 のコード削除に **追随していない** `docs/domain/*.md` の記述を現状のコードベースに合わせて整理する。コード変更は原則なし（docs のみ）。

## 背景

以下は **コードから既に削除済み** だが、ドキュメントに残存:

| 削除済み機能 | stale 記述の例 |
|--------------|----------------|
| `LLMSegmentConverter` / `llmWholeText` | `glossary.md` SegmentState.llmWholeText 節、`states.md` Enter 短絡確定 |
| `boundary_pref` | `scenarios.md` LLM 境界保存、`architecture.md` 一部 |
| `expandSuccessorPrefixes` | 会話前は docs 更新済みの可能性 — 要確認 |
| `virtualHistoryPrefix` | Phase 2 Step 4 完了 — glossary 要確認 |

**維持**: F6–F10（F9/F10 ローマ字確定含む）は一般 IME 互換のため docs 上も現状維持。

## 更新対象（チェックリスト）

| ファイル | 確認・修正内容 |
|----------|----------------|
| [`docs/domain/glossary.md`](../docs/domain/glossary.md) | `SegmentState.llmWholeText` 節削除。`virtualHistoryPrefix` 節が残っていれば削除 |
| [`docs/domain/states.md`](../docs/domain/states.md) | セグメント Enter の `llmWholeText` 言及削除 |
| [`docs/domain/scenarios.md`](../docs/domain/scenarios.md) | LLM セグメント / `boundary_pref` シナリオ節（S-XX）削除 or 「削除済み」注記。存在しないテスト参照（`SegmentBoundaryTests` 等）を削除 |
| [`docs/domain/architecture.md`](../docs/domain/architecture.md) | DatabaseManager テーブル数・廃止テーブル一覧が現状と一致しているか確認 |
| [`CLAUDE.md`](../CLAUDE.md) | LLM 機能一覧が現状と一致（F6–F10 は維持） |

## 検証

```bash
# stale 参照の grep（ゼロが理想）
rg -l 'llmWholeText|boundary_pref|LLMSegmentConverter|virtualHistoryPrefix|expandSuccessorPrefixes|SegmentBoundaryTests|InputHandlerSegmentLLMTests' docs/
```

## リスク

**なし** — ドキュメントのみ。

## 完了条件

- [ ] 上記 grep が docs 内でヒットしない（または意図的な歴史注記のみ）
- [ ] Phase 3 Step 1–2 の実施内容と docs が一致
