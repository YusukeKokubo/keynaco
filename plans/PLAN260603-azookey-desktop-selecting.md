---
status: implemented
created: 2026-06-03
related_commit: 62ca888
related_commits:
  - 0aa289b  # firstClause マージ・部分確定（Desktop .selecting 骨格）
  - adc85ac  # Phase 1: suffix/segmentize 境界フォールバック除去
  - e1ffa4a  # Phase 2: main 部分候補マージ・segment Options・AzooKey bbef9d2
  - 3e8247a  # 文節モード入り条件整理
  - 8f64dbe  # Phase 3: 境界（は/です）・候補エンジン優先・Xcode bbef9d2 同期
  - f887e43  # （旧）助詞 suffix — 境界では非使用・履歴参照のみ
  - e0585b7  # （旧）prefix 再変換 — 削除（merged フォールバックに置換）
  - 7b0ab4f  # （旧）multi-char suffix — 境界では非使用
  - 62ca888  # 履歴が engineClauseEnd を上書きしない回帰 + sandbox スクリプト
references:
  - azooKey-Desktop/Core/Sources/Core/InputUtils/SegmentsManager.swift
  - Core/Sources/Core/InputHandler+SegmentMode.swift
  - Core/Sources/Core/AzooKeyConversion.swift
  - Core/Sources/Core/AzooKeyConverter.swift
  - plans/POC260603-segment-boundary-suffix.md
---

# PLAN260603: 文節分割を AzooKey Desktop（`.selecting`）に寄せる

## 目的

Space 後の文節選択モードで、AzooKey と同様に **左端文節の長さをエンジン候補の `composingCount` で決め**、フラットな候補リストから表層を選び、Enter で部分確定 → 残りで再変換する。

見た目だけ合わせるのではなく、**境界の正本**を Desktop と同型にし、keynaco 独自の読みルール（suffix 剥がし・`segmentize` 依存）による誤分割をなくす。

---

## 進捗サマリ（2026-06-04 完了）

| Phase | 状態 | 結果 |
|-------|------|------|
| 0 計測 | ✅ | ROW テスト・`bbef9d2` 同期・sandbox/CLAUDE 追記 |
| 1 suffix 除去 | ✅ [`adc85ac`](adc85ac) | suffix 害を証明・除去 |
| 2 部分候補供給 | ✅ [`e1ffa4a`](e1ffa4a) | main マージ + 文節 Options で #1 #2 #4 #6 |
| 3 UI・境界仕上げ | ✅ [`8f64dbe`](8f64dbe) | #3 #4 達成・prefix 再変換削除・連続確定テスト強化 |
| 4 E2E・docs | ✅ | チェックリストテスト・sandbox スキル・`implemented` |

詳細ログ: [`POC260603-segment-boundary-suffix.md`](POC260603-segment-boundary-suffix.md)

---

## AzooKey 実機メモとの差（#4 意図的）

| 項目 | AzooKey 実機メモ（参考） | keynaco |
|------|-------------------------|---------|
| `こんにちは` + Space 初期境界 | 先頭 `こ`(1) になる報告あり | `こんにち`(4) + 残り `は`（部分候補 `inputLength` 優先） |

運用上は長い部分候補で問題なし。ROW / Core テスト / sandbox（`konnnichiha`）で固定。

---

## フェーズ別タスク（完了）

### Phase 0: 計測の固定

- [x] `SegmentBoundaryComparisonTests` をコミット（`adc85ac`）
- [x] `segment_boundary_compare.py` リポジトリ管理済
- [x] AzooKey 実機差分を PLAN 上に記録（#4）
- [x] Xcode `Package.resolved` を `bbef9d2` に同期
- [x] sandbox スキルに `konnnichiha`・文節境界の注意を追記

### Phase 1–2

- [x] suffix / segmentize 除去（`adc85ac`）
- [x] main マージ + 文節 Options（`e1ffa4a`）

### Phase 3

- [x] 境界・候補 UI（`8f64dbe`）
- [x] `clauseScopedEngineRows` の prefix **再変換 API 呼び出しを削除**（`merged` フォールバックのみ残す）
- [x] 連続確定テスト強化（`testSequentialEnterConfirmsOneSegmentAtATime`）
- [x] Shift+←/→ は `manualClauseEnd` ±1（`CompositionState` に Desktop `editSegment` 相当と明記）

### Phase 4

- [x] `testPlan260603ChecklistSegmentBoundaries`（#1–#4）
- [x] `CLAUDE.md` / sandbox スキル追記
- [x] `status: implemented`

---

## 計測コマンド

```bash
cd Core && swift test --filter SegmentBoundaryComparisonTests
cd Core && swift test --filter testHistoryDoesNotOverrideSegmentClauseEnd
python3 scripts/debug_ime.py watashihagakusei   # 要 keynaco 起動
python3 scripts/check_segment_history_boundary.py  # 履歴 seed 後の境界（要 keynaco）
# こんにちは: reset → konnnichiha → space
```

---

## フォローアップ: 履歴・境界学習（2026-06-04 triage）

PLAN 完了後に [`PLAN260429e`](PLAN260429e-segment-boundary-learning.md) 統合の要否を確認した。

| 経路 | `engineClauseEnd` を変えるか | 現状 |
|------|------------------------------|------|
| AzooKey 部分候補 `inputLength` | ✅ 正本 | Space 直後の既定境界 |
| `boundary_pref` | していた（廃止前） | **削除済**（[`PLAN260523g`](PLAN260523g-boundary-pref-removal.md) / CHANGELOG） |
| `recordPrefixes` / `fetchHistoryScoredMerged` | ❌ | 文節**表層**候補のみ（`LIKE '文節読み%'`） |
| Shift+←/→ → `manualClauseEnd` | ✅ セッション内のみ | 永続化なし |

**結論**: 変換履歴を増やしても文節境界長は変わらない（[`62ca888`](62ca888)・`testHistoryDoesNotOverrideSegmentClauseEnd`・`scripts/check_segment_history_boundary.py`）。`boundary_pref` の復活は PLAN260603 と衝突しやすい。**Deferred** — 手動境界の永続化だけ別途検討するなら [`PLAN260429e`](PLAN260429e-segment-boundary-learning.md) 参照。

---

## 関連

- POC: [`plans/POC260603-segment-boundary-suffix.md`](POC260603-segment-boundary-suffix.md)
- 境界学習 triage: [`plans/PLAN260429e-segment-boundary-learning.md`](PLAN260429e-segment-boundary-learning.md)
- AzooKey 参照: `~/src/github.com/azooKey/azooKey-Desktop/.../SegmentsManager.swift`
