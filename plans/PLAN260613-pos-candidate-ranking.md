---
status: in-progress
created: 2026-06-13
---

# PLAN260613: 品詞による候補ウィンドウ表示優先度

## 目的

候補ウィンドウ内の並びを品詞で調整し、**内容語（名詞・固有名詞）を優先**、**機能語（助詞・接続詞等）を下げる。`docs/concept.md` 指針 1「機能語と内容語でサジェスト価値が違う」を候補表示に反映する。

## 背景

### コンセプトとの整合

| 語種 | サジェスト価値 | 現状 |
|------|--------------|------|
| 名詞・固有名詞 | 高い | AzooKey 辞書順・履歴スコアのみで並ぶ |
| 動詞・形容詞 | 文脈依存 | `pos IS NULL` として区別なし |
| 助詞・接続詞 | 低い（リズム入力） | 履歴取得時に接続詞・感動詞のみ除外 |

### 実 DB 調査（2026-06-13、`~/Library/Application Support/keynaco/history.db`）

| pos | 語数（distinct output） | 使用回数 |
|-----|------------------------|---------|
| noun | 2,198 | 7,509 |
| **(NULL)** | **1,596** | **3,775** |
| proper_noun 系 | 436 | 1,317 |
| other 系 | 69 | 239 |

- 使用回数ベース: 名詞+固有名詞 **約 69%**、NULL **約 29%**
- NULL の **75%** は 5 文字以下の短語。長いフレーズ（>10 文字）は 7 語 / 39 回のみ
- NULL 上位: 欲しい(24)、今(22)、難しい(20)、調べて(19)、見て(13)、思う(13) — 動詞・形容詞が多い
- 同一読みで名詞 vs NULL が競合（各 5 回以上）するケースは **ほぼ無い**（7 読みのみ）
- 旧 LLM 由来の `other` 誤分類が残存（教えて・嬉しい・今は 等、計 239 回）

### NULL の意味（重要）

`AzooKeyLcidMapper` は名詞・固有名詞**のみ** `pos` を返す設計。動詞・形容詞は意図的に `nil` → DB 上 `pos IS NULL`。

```swift
// AzooKeyLcidMapper.swift
/// 名詞・固有名詞のみ返す。動詞・形容詞等は keynaco 上の価値が低いため `nil`。
```

**NULL ≠ 分類失敗**。NULL を一律で下げると、履歴で高頻度の動詞・形容詞（見て・思う・欲しい）まで落ちるリスクがある。

### 現状の候補パイプライン

1. **セクション順**（`CandidateLayout`）: 固定枠 → ユーザー辞書 → Zenzai → 履歴 → AzooKey 辞書 → カタカナ。POS 無関係
2. **履歴**（`fetchHistoryScoredMerged`）: 時間減衰スコア降順。接続詞・感動詞のみ SQL で除外（[`PLAN260525b`](PLAN260525b-candidate-filter-prompt.md) の blocklist 化済み）
3. **AzooKey 辞書**（`azooKeyDict` セクション）: AzooKey/Zenzai の返却順のまま。`Candidate.data[].lcid` は取得済みだが並び替えに未使用

## 設計方針

### 原則

1. **履歴の主ソートはスコア優先** — ユーザーが実際に選んだ頻度を最優先
2. **POS はセクション内の二次ソート** — 同スコア帯・辞書候補の並び替えに使う
3. **NULL の一律降格はしない** — 動詞・形容詞の履歴を殺さない
4. **lcid ベース** — 候補取得時点で分類可能。DB の `pos` 列に依存しない（未確定語・辞書のみ候補にも効く）

### POS ランク定義（案）

| rank | 対象 | 例 |
|------|------|-----|
| 0 | proper_noun/* | 東京、IME |
| 1 | noun, noun/suffix | 表示、設定 |
| 2 | verb, adjective（新規 lcid 分類） | 調べる、難しい |
| 3 | NULL（lcid 不明・未分類） | — |
| 4 | particle, other/conjunction, other/interjection | が、しかし |

`other`（旧 LLM 残存）は backfill で再分類し、上記に吸収させる。

### 適用範囲（段階的）

| Phase | 対象 | リスク | 期待効果 |
|-------|------|--------|---------|
| **A** | AzooKey 辞書セクション内の並び替え | 低 | 辞書候補のノイズ削減。lcid が取れるので即効 |
| **B** | 履歴のタイブレーカー（`score` 同値帯のみ） | 低 | `maxHighHistoryCount=3` の枠争いを改善 |
| **C** | 長文 NULL ペナルティ（`output.count > 10`） | 極低 | フレーズ履歴のノイズ削減（7 語のみだが害なし） |
| **D** | lcid から verb/adjective/particle を明示タグ化 | 中 | NULL 意味の明確化。backfill・将来の blocklist 拡張に使える |

**やらないこと**

- 履歴の主ソートを POS に置き換える
- NULL の一律非表示（allowlist 復活。`PLAN260525b` で棄却済みの問題が再発）
- Zenzai top-1 プロモート行の POS による差し替え

## 実装ステップ

### Step 1: `POSRank` ユーティリティ（`Core/`）

```swift
enum POSRank: Int, Comparable, Sendable {
    case properNoun = 0
    case noun = 1
    case verbOrAdjective = 2
    case unknown = 3
    case functionWord = 4

    static func from(lcid: Int) -> POSRank { ... }
    static func from(pos: String?) -> POSRank { ... }  // 履歴用
}
```

- `AzooKeyLcidMapper` を拡張し、動詞・形容詞・助詞の lcid レンジを追加（Step 4 と同時でも可）
- テスト: `AzooKeyLcidMapperTests` / 新規 `POSRankTests`

### Step 2: AzooKey 候補の POS ソート（Phase A）

`AzooKeyConverter.requestCandidates` の返却、または `fetchAzooKeyCandidates` 直後で `[String]` を安定ソート:

```swift
candidates.sorted { a, b in
    let ra = posRank(for: a, reading: h)
    let rb = posRank(for: b, reading: h)
    if ra != rb { return ra < rb }
    return originalIndex(a) < originalIndex(b)  // 安定ソート
}
```

- `posRank` はキャッシュ済み `[Candidate]` から `lcid` を引く（`lcidForCommitted` の辞書ルックアップは候補リスト全体には重いので、`requestCandidates` 内で `Candidate` 配列を保持してテキスト→lcid マップを作る）
- Zenzai top-1 プロモート対象（`azooKeyCandidates.first`）はソート前の top-1 を維持

### Step 3: 履歴タイブレーカー（Phase B）

`fetchHistoryScoredMerged` の `ORDER BY` を拡張:

```sql
ORDER BY s DESC, pos_rank ASC, MAX(used_at) DESC
```

`pos_rank` は Swift 側でソートする方が SQL 拡張を避けられる（`pos` 文字列→rank の CASE 式は保守コスト高）:

```swift
results.sorted {
    if $0.score != $1.score { return $0.score > $1.score }
    return POSRank.from(pos: $0.pos) < POSRank.from(pos: $1.pos)
}
```

スコア差が `epsilon`（例: 0.01）以内のときだけ POS で並べ替える、という制約も検討可。

### Step 4: lcid 分類拡張 + backfill（Phase D）— **実装済み**

`AzooKeyLcidMapper` に verb / adjective / particle レンジを追加。`history.lcid INTEGER` 列を追加し、分類時に生 lcid も保存。backfill は `pos IS NULL` / `other` / `lcid IS NULL`（接続詞・感動詞除く）を再分類。

### Step 5: 長文ペナルティ（Phase C、任意）

履歴ソート時に `output.count > 10` な NULL を rank 3.5 相当で下げる。実データ上 7 語のみだが実装コスト極小。

## 変更ファイル（想定）

| ファイル | 変更内容 |
|---------|---------|
| `Core/Sources/Core/AzooKeyLcidMapper.swift` | verb/adjective/particle lcid レンジ追加 |
| `Core/Sources/Core/POSRank.swift`（新規） | lcid / pos 文字列 → rank 変換 |
| `Core/Sources/Core/AzooKeyConverter.swift` | 候補返却時に lcid マップ保持、またはソート済みテキスト返却 |
| `Core/Sources/Core/InputHandler+Candidates.swift` | AzooKey 候補の二次ソート（Converter 側でやらない場合） |
| `Core/Sources/Core/DatabaseManager+History.swift` | 履歴結果のタイブレーカーソート |
| `Core/Sources/Core/AzooKeyPOSBackfill.swift` | `other` 再分類対象の追加 |
| `Core/Sources/CoreTests/POSRankTests.swift`（新規） | rank 変換のユニットテスト |
| `Core/Sources/CoreTests/CandidateSectionBuilderTests.swift` | AzooKey セクション並びの回帰テスト |

## 検証

### ユニットテスト

- 同一 rank 内は元の順序を維持（安定ソート）
- Zenzai top-1 はソート前 first を維持
- 履歴: スコア差が大きいとき POS で順序が入れ替わらない

### sandbox 手動確認（`/keynaco-ime-sandbox`）

| 読み | 確認点 |
|------|--------|
| `かんじ` | 名詞「感じ」が動詞系より上か |
| `きょう` | 固有名詞「東京」が助詞付きより上か |
| `しらべ` | 履歴「調べて」（動詞）がスコア優先で残るか |
| `ひょうじ` | 名詞「表示」が辞書候補の上位か |

### DB ドライラン（任意）

```sql
-- POS ソート導入後に highHistory 枠の構成変化を比較
SELECT output, pos, SUM(count) AS s FROM history
WHERE input LIKE 'かんじ%'
GROUP BY output ORDER BY s DESC LIMIT 5;
```

## 関連 plan

| plan | 関係 |
|------|------|
| [`PLAN260525b-candidate-filter-prompt.md`](PLAN260525b-candidate-filter-prompt.md) | 履歴 blocklist（接続詞・感動詞除外）済み。本 plan は並び替え層 |
| [`PLAN260524-pos-tag-taxonomy.md`](PLAN260524-pos-tag-taxonomy.md) | pos タグ体系。lcid 拡張時に参照 |
| [`PLAN260519-candidate-section-declaration.md`](PLAN260519-candidate-section-declaration.md) | セクション構造。セクション**間**順序は変えない |
| [`PLAN260520c-noun-bigram.md`](PLAN260520c-noun-bigram.md) | 名詞 bigram（未実装）。POS 分類精度は共通基盤 |

## 判断基準（POC 後）

| 結果 | 判断 |
|------|------|
| AzooKey セクションで名詞が目視で上位に来る | Phase A をマージ |
| 履歴でよく使う動詞（見て・思う）が消える | Phase B を弱める or 撤回 |
| lcid 分類拡張で NULL が 50% 以下に | Phase D を継続 |
| sandbox で体感改善なし | Phase A のみ留保、B/C は見送り |

## 実装順序

1. ~~`POSRank` + lcid 拡張 + テスト~~ → **Phase D 完了**（`AzooKeyLcidMapper` に verb/adjective/particle、backfill が `other` も再分類）
2. Phase A（AzooKey ソート）→ sandbox 確認
3. Phase B（履歴タイブレーカー）→ 回帰テスト
4. ~~Phase D（backfill 拡張）~~
5. Phase C（長文ペナルティ、任意）
