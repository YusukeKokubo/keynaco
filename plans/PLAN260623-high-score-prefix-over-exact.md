---
status: implemented
created: 2026-06-23
related_commit:
---

# PLAN260623: 高スコア前方一致履歴を完全一致より優先（打鍵中）

## 目的

打鍵中（`.whileTyping`）に、**merged スコアが十分高い前方一致履歴**を、低スコアの読み完全一致履歴より先に表示・フォーカスする。

典型例: `じょう` 入力時に score≈9 の「上」（exact）より score≈93 の「情報共有」（prefix）を先頭付近に出す。

`docs/concept.md` 指針 3「履歴は使うほど自分仕様になる」と、前方一致・予測による打鍵削減の方向性に合わせる。

## 背景

### 観測（2026-06-23）

- `fetchHistoryScoredMerged("じょう")` で「情報共有」score≈93、「上」exact score≈9
- `exactMatchFirstSectionOrder` により exact → 辞書 6 件 → prefix の順
- 候補ウィンドウは 8 行固定のため prefix 履歴が画面外（9 行目以降）
- divergence_log: `candidates: ["上","上手",…,"城"]` に「情報共有」なし

### PLAN260614 との関係

PLAN260614 は「読み完全一致履歴は閾値なしで最優先」としていた。本件は **低スコア exact が高スコア prefix を押しのけるケースに限定**して緩和する。

## 設計

### 昇格条件（`HistoryPrefixPromotion`）

打鍵中のみ、前方一致履歴 output ごとに:

```
prefixScore >= minScore (20)
AND prefixScore >= bestExactScore * ratio (3)
```

- `prefixScore`: `fetchHistoryScoredMerged` の SUM（`highHistory` 構築時と同じ）
- `bestExactScore`: `fetchHistoryExactScored` の最高スコア（exact 行のみ、prefix SUM 禁止）

### 候補並び

昇格対象があるとき `prefixPromotedSectionOrder`:

```
fixedHiragana → userDict → promotedPrefixHistory → exactMatchHistory
→ number/dateTime → azooKeyDict → highHistory（昇格しなかった残り）
```

`historyEnd` は `promotedPrefixHistory` + `exactMatchHistory` まで（従来どおり末尾 `highHistory` は対象外）。

### 初期行

1. 昇格 prefix の先頭（スコア昇格済みのため品詞×モーラ閾値はバイパス）
2. 読み完全一致履歴
3. 以降は現行どおり

`whileTypingInitialRow` も昇格 prefix 行を exact と同様に常にフォーカス可能とする。

`lastInitialRowReason`: `"promotedPrefixHistory"`

### スコープ外

- `.explicit`（Space）トリガ — 現行維持
- `resolvedHistoryReading` による短い読み DB 汚染 — 別件（`じょう→上手` 問題）
- 末尾 `highHistory` の `historyEnd` 拡張 — 本 PLAN では触らない

## テスト

| ケース | 期待 |
|--------|------|
| `じょう` + exact「上」(9) + prefix「情報共有」(93) | 昇格・初期行 prefix 側 |
| `よう` + exact「用」(高) + prefix「要件」(低) | exact 維持（既存回帰） |
| 昇格なし | 現行と同一 |
| `promotedPrefixHistory` section order | 辞書より前、exact より前 |

## 関連

- [PLAN260614-prefix-focus-mora-thresholds.md](PLAN260614-prefix-focus-mora-thresholds.md)
- [PLAN260621b-recency-weight-boost.md](PLAN260621b-recency-weight-boost.md)
