---
status: implemented
created: 2026-06-03
related_commit: 8f64dbe
related_plan: plans/PLAN260603.md
related_commits:
  - adc85ac  # Phase 1
  - e1ffa4a  # Phase 2
  - 3e8247a  # 文節モード入り条件
  - 8f64dbe  # Phase 3 境界・候補表示
---

# POC260603: 文節境界 — suffix 除去と部分候補供給

親 PLAN: [`PLAN260603.md`](PLAN260603.md)（Phase 4・残タスクは PLAN 側で追跡）

## Phase 1 — suffix / segmentize 境界フォールバック除去

### 変更

- `defaultClauseEndFromConversion` から `clauseEndStrippingTrailingParticle` を削除
- `defaultClauseEnd` から `segmentizeFirstReading` 引数を削除
- `enterSegmentMode` / 部分確定後の `segmentize` 先頭参照を削除
- `AzooKeyConverter.segmentize` ループから suffix フォールバックを削除

### 比較結果（`SegmentBoundaryComparisonTests` / stderr ROW）

| ID | 入力 | engineEnd (前→後) | imeEnd | imeRemain | 判定 |
|----|------|-------------------|--------|-----------|------|
| 1 anataha | あなたは | strip=3 参照のみ、end **4**（全文） | 4 | （空） | **劣化**（AzooKey: 3\|は） |
| 2 gakuseidesu | strip=4 参照のみ、end **6** | 6 | （空） | **劣化**（4\|です） |
| 3 watashihagakusei | partial 私はが:5, end 5 | 5 | くせい | **未解決**（変な partial 依存） |
| 4 konnitiha | strip=4 参照のみ、end **5** | 5 | （空） | **#4 改善**: 残り「は」単独・「今一」系なし |
| 5 gakusei | 4 | 4 | （空） | 変化なし |
| 6 ryuugakuseidesu | strip=7 参照のみ、end **9** | 9 | （空） | **劣化**（7\|です 想定） |

### 結論

**仮説は半分成立。** suffix 除去で `konnitiha` の誤分割は止まるが、#1 #2 #6 は firstClause 部分候補なしでは全文境界に戻る。

→ **Phase 2 へ進む**

---

## Phase 2 — 部分候補供給（2026-06-03）

### 判明したこと

- 部分長（`あなた:3`, `こんにち:4`）の多くは **`mainResults` 側**に入る
- Desktop 同型の `mergedFirstClauseResults` + 文節用 Options（予測 off, rich, separator）で suffix なし再現
- AzooKey `bbef9d2` + `PredictionMode`

### suffix なし ROW（再計測）

| ID | engineEnd | imeEnd | 備考 |
|----|-----------|--------|------|
| 1 | 3 | 3 | ✅ あなた\|は |
| 2 | 4 | 4 | ✅ がくせい\|です |
| 3 | 8 | 8 | ❌ 私は:4 優先（わたし:3 要） |
| 4 | 4 | 4 | ✅ こんにち\|は（先頭表層は要改善） |
| 5 | 4 | 4 | ✅ 単語全文 |
| 6 | 7 | 7 | ✅ 留学生\|です |

### 結論

**仮説成立。** main マージ + 文節 Options で #1 #2 #4 #6 は境界一致。#3 境界・#4 表層は Phase 3 へ。

---

## Phase 3 — 境界仕上げ・候補 UI（2026-06-04）

コミット: `3e8247a`（入り条件）、`8f64dbe`（境界・表示）。

### 変更

| 領域 | 内容 |
|------|------|
| 境界 | `preferredMorphologicalSplitIndex`（です接尾 → 話題「は」直前）+ 分割位置で読み一致表層を優先 |
| 文節入り | ひらがな優先・短語・日時/ユーザー辞書は通常窓（`3e8247a`） |
| 候補 UI | `segmentEngineOverride` 時は予測セクション省略、エンジン行を先頭 |
| エンジン行 | `clauseEnd` 一致の `firstClause` のみ + `firstClause` 返却順ソート |
| 初期行 | `initialEngineRowIndex` / `displayIndex` で読み（`こんにち`）一致を優先 |
| ビルド | Xcode `Package.resolved` → `bbef9d2` |

### ROW / Core テスト（再計測）

| ID | engineEnd | imeEnd | 先頭表層 | 判定 |
|----|-----------|--------|----------|------|
| 3 | 3 | 3 | わたし | ✅ |
| 4 | 4 | 4 | 今日/こんにち（テストは `setComposedReading`） | ✅ |

### 実機（デバッグソケット、`8f64dbe` ビルド）

| 入力 | `segmentTexts` | 先頭候補 |
|------|----------------|----------|
| `watashihagakusei` + Space | `['わたし', 'はがくせい']` | 私 / **わたし** |
| `konnnichiha` + Space | `['こんにち', 'は']` | **今日** / **こんにち** |

**ローマ字の罠**: `konnitiha` / `konnichiha` → `こんいちは`。`こんにちは` は **`konnnichiha`**（`n`×3）またはひらがな直接入力。

### 結論

**#3 #4 の仮説成立。** 最長部分だけでは `私は:4` が勝つため、形態素境界（は/です）+ 読み一致が必要。表層の「艮一」は予測候補の先頭混入が原因で、文節モードのエンジン優先で解消。

**残り（2026-06-04 時点）**: 上記は PLAN260603 で完了。履歴・`boundary_pref` triage → [`PLAN260603.md`](PLAN260603.md) フォローアップ節・[`PLAN260429e.md`](PLAN260429e.md)（deferred）。
