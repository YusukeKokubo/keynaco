---
status: implemented
created: 2026-06-24
related_commit: 729ca0e
supersedes_triage:
  - PLAN260623-high-score-prefix-over-exact.md
---

# PLAN260624: 候補リストの統一スコアランキング

> **実装ノート (2026-06-24)**: Phase 1〜3 すべて完了。コミットシリーズ `39ef182`（feat: unify ranking via score builder）→ `1954938`（hiraganaPreferred score 化）→ `3228ef7`（section builder 削除）→ `f49ab9d`（flatten global score order）→ `729ca0e`（drop historyEnd）。`HistoryPrefixPromotion` / `CandidateSectionBuilder` / `CandidateLayout` / `CandidateFixedSlot` は全削除。挙動の正本は `CandidateScoreBuilder` + `ScoredCandidate` のコードとテスト。下記「未決」項目の最終値はコード参照。

## 目的

候補表示・初期フォーカスを **単一のスコア降順** に統一し、セクション優先順位・複数閾値・`InitialRowPolicyResolver` の分岐を削減する。

- 「高スコア履歴が低スコア exact より前」は **並び替えルールではなくスコア差** で自然に出る
- `hiraganaPreferred` の固定枠も **スコア加算** に吸収する
- [PLAN260623](PLAN260623-high-score-prefix-over-exact.md) で入れた `promotedPrefixHistory` / `HistoryPrefixPromotion` は **過渡期実装** として将来削除対象

## 背景：今の複雑さ

| レイヤ | 役割 | 問題 |
|--------|------|------|
| DB `recencyExpr` | 履歴の raw score | 正本として良い |
| `historyRecencyScoreCutoff` 0.5 | 載せる/載せない | OK |
| `maxHighHistoryCount` 3 | prefix 件数 cap | スコア順 top-N に統合可能 |
| `HistoryPrefixPromotion` | exact より前へ | セクション順と二重管理 |
| `CandidateSectionBuilder` | exact / promoted / high / dict 分離 | sectionOrder が 3 種 |
| `CandidateLayout` | flatten + `candidateSources` | 削除済み |
| `InitialRowPolicyResolver` | 初期行（exact > promoted > prefix focus > azooKey） | 並びと別ロジック |
| `CandidateFixedSlot.hiragana` | ひらがな先頭固定 | スコア外の特例 |
| `whileTypingInitialRow` | モーラ閾値で履歴行フィルタ | スコアと別ゲート |

**症状**: `じょう` でスコア 93 の「情報共有」が載るのに画面外、など **スコアと表示位置が乖離** しやすい。

## 設計方針

### 1. 中間表現: `ScoredCandidate`

```swift
struct ScoredCandidate: Sendable, Equatable {
    enum Source: Sendable {
        case historyExact
        case historyPrefix
        case userDict
        case azooKey(rank: Int)      // API 返却順 0-based
        case hiraganaPreferred       // 組成読みそのもの
        case hiraganaBuiltin         // HiraganaPreferredBuiltins
        case number
        case dateTime
    }
    let text: String
    let score: Double
    let source: Source
}
```

- **同一 `text` は最高スコア 1 件だけ残す**（source は max 側を保持、または `sources: Set`）
- 最終 `candidates: [String]` は `score` 降順 → 同点 tie-break（後述）

### 2. スコア付けルール

#### 履歴（正本: 既存 `recencyExpr`）

| 種別 | score |
|------|-------|
| exact | `fetchHistoryExactScored` の行スコア |
| prefix | `fetchHistoryScoredMerged` の SUM スコア |

載せない: `score < 0.5`（現行 cutoff 維持）。

#### ユーザー辞書

- exact: 固定スコア **50**（履歴の「よく使う語」より下、たまに使う履歴より上 — 要 POC 調整）
- prefix: **30**（または履歴 prefix より常に劣後 — 要 POC）

#### AzooKey / Zenzai

- **API 返却順から単調減衰スコア**（lcid ソートは再導入しない。[rejected P-7](../docs/rejected.md)）
- 例: `score = 10.0 / (1.0 + rank)` または `score = max(0, 10 - rank)`
- Zenzai top-1 プロモートは **rank=0 の候補にボーナス**（+5 等）で表現可能

#### hiraganaPreferred（固定枠のスコア化）

組成読み `h` が `hiraganaPreferredSet` または `HiraganaPreferredBuiltins` に含まれるとき、**候補 `h`（ひらがな）に加算**:

| 条件 | 加算 |
|------|------|
| `hiraganaPreferredSet`（ユーザー設定） | **+100** |
| `HiraganaPreferredBuiltins`（組み込み助詞等） | **+80** |
| 履歴に同じ読みの exact がある | `max(hiraganaBonus, historyExactScore)` — 履歴と競合させない |

意図（現行 PLAN260518 と同等）:

- 「の」→ 履歴「ノックアウト」より **ひらがな「の」** が上
- 助詞は内容語履歴（score 20+）より下に留まるよう **+80 < 典型 prefix 履歴** の関係を POC で確認

組み込み助詞は **打鍵中 dismiss**（機能語 UI 非表示）は維持。スコア化と矛盾しない（候補リストに載せない / 載せても dismiss）。

#### 数値・日時

- 固定 **5**（特殊変換。マッチ時のみリストに追加）

### 3. 並びと初期行

```
scored = merge(all sources)
filtered = scored.filter { $0.score >= cutoff && passesTriggerRules }
sorted = filtered.sorted(by: scoreDesc, then: tieBreak)
candidates = sorted.map(\.text)
initialRow = 0   // 原則先頭。explicit 時のみ別途検討
```

**tie-break 順**（同点時のみ）:

1. `historyExact` > `historyPrefix` > `userDict` > `azooKey` > その他
2. 同 source 内は API 順 / DB 順を維持

**削除・縮小**:

- `CandidateFixedSlot` / `fixedHiragana` セクション → スコア条目
- `exactMatchHighHistory` / `highHistory` / `promotedPrefixHistory` 三分割 → `history*` source のみ
- `HistoryPrefixPromotion` → 削除
- `CandidateLayout.defaultSectionOrder` / `exactMatchFirstSectionOrder` / `prefixPromotedSectionOrder` → **単一 flatten**
- `InitialRowPolicyResolver.resolve` の exact/promoted/prefix 分岐 → **原則不要**（残すなら edge case のみ）

### 4. 残す非スコア例外（最小限）

| 例外 | 理由 |
|------|------|
| Shift+Delete | `candidateSources` の `history*` 行のみ（`historyEnd` インデックスは削除済み） |
| 打鍵中 機能語 dismiss | `HiraganaPreferredBuiltins` 先頭 → UI 非表示（concept 指針 1） |
| `.explicit` vs `.whileTyping` | dismiss / defer AzooKey はトリガー依存のまま |
| 外来語記号 → カタカナ初期行 | スコア化可能だが Phase 2（読み属性ボーナス） |

モーラ閾値（PLAN260614）: **Phase 2 で検討**。統一スコア後に prefix 暴発が再発するなら `score *= moraGateFactor` に置換。初期実装では **スコア順のみ** で POC。

## マイグレーション（段階）

### Phase 1: 履歴 + 辞書 + AzooKey

- `CandidateScoreBuilder.build(reading:trigger:sources:) -> [ScoredCandidate]`
- `CandidateSectionBuilder` を置換または内部で score builder 呼び出し
- 既存テストの期待順序を score モデルに書き換え
- sandbox: `じょう` / `よう` / `kanzi` / `の`

**完了条件**: PLAN260623 の `じょう→情報共有` ケースが **promoted セクションなし** で先頭付近に出る。

### Phase 2: hiraganaPreferred スコア化

- `fixedSlot=.hiragana` 削除
- `HiraganaPreferredBuiltins` dismiss ロジックは維持
- 回帰: `InputHandlerCandidatesTests` の hiraganaPreferred 系、`の` + 履歴ノックアウト

### Phase 3:  dead code 削除

- `HistoryPrefixPromotion.swift`
- `InitialRowPolicyResolver` の大部分（`prefixFocusCandidate` / `whileTypingInitialRow` を score 式に統合できるなら削除）
- 3 種 `sectionOrder`
- `CandidateBuildDiagnostics` の section ラベル → `source` ラベル

## テスト戦略

| 層 | 内容 |
|----|------|
| ユニット | `CandidateScoreBuilderTests` — 各 source の score 合成・dedup・tie-break |
| 回帰 | `ScenarioRegressionTests` — worked example 維持 |
| sandbox | `test_suite`: jou/情報共有, you/用, の/ひらがな優先, kanzi/漢字 |
| 拒否 | lcid による global ソート再導入（P-7） |

## リスク

| リスク | 対策 |
|--------|------|
| AzooKey 順を score 化すると Zenzai 逆転 | rank ベースのみ。lcid ソート禁止 |
| 助詞 +100 で内容語を押しのける | builtin +80 / user +100 を POC。暴発時は builtin を +40 に |
| 数値・日時が埋もれる | マッチ時 score=5 固定。必要なら +15 |
| 実装中の二重経路 | Phase 1 完了まで PLAN260623 コードは残し、Phase 3 で一括削除 |

## 未決（POC で決める）

1. ユーザー辞書 exact/prefix の固定 score（50/30 案）
2. AzooKey rank → score の式（`10/(1+rank)` vs `10-rank`）
3. hiraganaPreferred ボーナス量（+80/+100 案）
4. prefix 件数 cap 3 を **global top-N** にするか、history だけ cap するか

## 関連

- [PLAN260623-high-score-prefix-over-exact.md](PLAN260623-high-score-prefix-over-exact.md) — 過渡期（implemented）
- [PLAN260614-prefix-focus-mora-thresholds.md](PLAN260614-prefix-focus-mora-thresholds.md) — モーラ閾値（Phase 2 で再評価）
- [PLAN260518-hiragana-preferred.md](PLAN260518-hiragana-preferred.md) — fixedSlot → スコア化で置換
- [docs/concept.md](../docs/concept.md) 指針 1・3
- [docs/rejected.md](../docs/rejected.md) P-7（lcid ソート禁止）
