---
status: in-progress
created: 2026-06-24
---

# PLAN260624d: 履歴の二段抽出を `HistoryEntry` 配列に統一

## 背景

PLAN260624 系の仕様シンプル化路線で、候補ロジック上ほぼ最後に残った drift。

現状は履歴を 4 フィールドに分けて持ち回っとる:

```swift
exactMatchHighHistory: [String]
highHistory: [String]                    // prefix
exactMatchScores: [String: Double]
prefixHistoryScores: [String: Double]
```

これが `CheapCandidateSources` / `CandidateListSources` / `CandidateScoreBuilder.BuildInput` の 3 箇所で同じ形で並ぶ。

## 設計

### `HistoryEntry` 型を Core に新設

```swift
public struct HistoryEntry: Sendable, Equatable {
    public let output: String
    /// `input = reading` の単行スコア（exact 由来）。0.5 未満 / 未該当なら nil。
    public let exactScore: Double?
    /// `LIKE 'reading%'` の SUM スコア（prefix 集計）。0.5 未満 / 未該当なら nil。
    public let prefixScore: Double?
}
```

`exactScore` と `prefixScore` を **1 エントリに併存**させる。同 output が両方から出る場合、1 エントリに両方の score が乗る。

### 持ち回りを 1 フィールドに

`CheapCandidateSources` / `CandidateListSources` / `CandidateScoreBuilder.BuildInput`:

```swift
// 旧
exactMatchHighHistory: [String]
highHistory: [String]
exactMatchScores: [String: Double]
prefixHistoryScores: [String: Double]

// 新
historyEntries: [HistoryEntry]
```

### `ScoredCandidate.Source` は無変更

`.historyExact` / `.historyPrefix` の 2 ケースは維持。観測ラベル（divergence_log の `scored_sources` で `"historyExact:...(score)"`）の解像度を保つため。builder 内では 1 エントリから 2 つの `ScoredCandidate` を upsert する場合あり（同 output で exact / prefix 両方のスコアがあるケース）。

### DB クエリは別のまま

`fetchHistoryExactScored` と `fetchHistoryScoredMerged` は触らない。SQL の都合 (`WHERE input = ?` vs `WHERE input LIKE ?% GROUP BY output`) で別クエリにせざるを得ない。merge は `InputHandler+Candidates` で行う。

## Phase

- [ ] **Phase 1**: `HistoryEntry` 型を Core/ に新設、ユニットテスト追加
- [ ] **Phase 2**: `CandidateScoreBuilder.BuildInput` を `historyEntries` に変更、build 内ループ統合
- [ ] **Phase 3**: `InputHandler+Candidates` の `CheapCandidateSources` / `CandidateListSources` を `historyEntries` に変更、`collectCheapCandidateSources` で merge
- [ ] **Phase 4**: 既存テスト（`CandidateScoreBuilderTests`, `ResolverEquivalenceTests`, `CandidateScoredLayoutTests` 等）の初期化を書き換え
- [ ] **Phase 5**: sandbox で挙動が変わらないことを確認（`じょう→情報共有`, `ai→Acme/愛/...`）

## スコープ外

- DB クエリの統合（SQL 都合で別のまま）
- `ScoredCandidate.Source` の enum 変更（観測ラベル維持）
- `historyExact` vs `historyPrefix` tie-break の変更（既存仕様維持）

## リスク

| リスク | 対策 |
|--------|------|
| 既存テストの広範囲更新 | Phase 4 で集中的に対応、初期化ヘルパで吸収できれば diff 圧縮 |
| 同 output が exact / prefix 両方にあるケースの挙動変化 | Phase 2 の builder 内ロジックで「2 つの ScoredCandidate を upsert」を維持。`upsert` の dedup ロジックで現状と同じ結果になる |

## 関連

- [PLAN260624-unified-candidate-scoring.md](PLAN260624-unified-candidate-scoring.md)
- [PLAN260624b-resolver-explicit-cleanup.md](PLAN260624b-resolver-explicit-cleanup.md)
- [PLAN260624c-drop-hiragana-firstmatching.md](PLAN260624c-drop-hiragana-firstmatching.md)
