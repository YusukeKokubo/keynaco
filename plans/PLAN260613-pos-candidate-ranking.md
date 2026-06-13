---
status: in-progress
created: 2026-06-13
---

# PLAN260613: lcid による候補ウィンドウ表示優先度

## 目的

候補ウィンドウ内の並びを **AzooKey 接続 ID（`lcid`）** で調整し、内容語を優先・機能語を下げる。`docs/concept.md` 指針 1「機能語と内容語でサジェスト価値が違う」を候補表示に反映する。

## `pos` と `lcid` の役割分担

| 列 / 概念 | 役割 | 使う場所 |
|-----------|------|---------|
| **`lcid`** | ロジックの正本。AzooKey 辞書と同じ接続 ID（細分類・活用形・接続制約を含む） | 候補並び替え、履歴タイブレーカー、blocklist 判定 |
| **`pos`** | 人間向け表示ラベル。`lcid` から派生した粗い品詞名 | 設定画面「変換履歴」、デバッグ表示、将来の UI |

**方針**: ランキング・フィルタは `lcid`（または `lcid` から導く rank）のみで行い、`pos` 文字列でのソート・判定はしない。`pos` は `AzooKeyLcidMapper` が `lcid` → 表示用タグに写像する層として維持する。

### 同じ `pos` で `lcid` が違う理由（参考）

`lcid` は品詞大分類ではなく IPADic 系の接続 ID。例:

- 名詞: 1283（一般）、1287（形容動詞語幹）、1314（副詞的名詞）→ いずれも UI 上 `noun`
- 動詞: 619（辞書形）、625（て形）、817（別活用帯）→ いずれも UI 上 `verb`

候補ランキングで差をつけたいときは `pos` ではなく `lcid` が必要。

## 背景

### コンセプトとの整合

| 語種 | サジェスト価値 | 現状 |
|------|--------------|------|
| 名詞・固有名詞 | 高い | AzooKey 辞書順・履歴スコアのみで並ぶ |
| 動詞・形容詞 | 文脈依存 | 並び替え未適用（DB には `lcid` 保存済み） |
| 助詞・接続詞 | 低い（リズム入力） | 履歴取得時に接続詞・感動詞のみ SQL で除外 |

### 実 DB 調査（2026-06-13）

調査時点では `pos IS NULL` が 29% あったが、Phase D 実装後は backfill で `pos` / `lcid` が埋まる。NULL 残存は辞書にないフレーズ・接続詞リスト由来のみ。

### 現状の候補パイプライン

1. **セクション順**（`CandidateLayout`）: 固定枠 → ユーザー辞書 → Zenzai → 履歴 → AzooKey 辞書 → カタカナ。ランク無関係
2. **履歴**（`fetchHistoryScoredMerged`）: 時間減衰スコア降順。接続詞・感動詞のみ SQL で除外
3. **AzooKey 辞書**（`azooKeyDict` セクション）: AzooKey/Zenzai の返却順のまま。`Candidate.data[].lcid` は取得済みだが並び替えに未使用
4. **DB**: `history.pos`（表示用）+ `history.lcid`（ロジック用）を保存。設定画面に両列表示

## 設計方針

### 原則

1. **履歴の主ソートはスコア優先** — ユーザーが実際に選んだ頻度を最優先
2. **`lcid` はセクション内の二次ソート** — 同スコア帯・辞書候補の並び替えに使う
3. **`pos` は表示専用** — ランキングロジックからは参照しない（`lcid` 欠落時のみ `pos` でフォールバック可）
4. **候補取得時は辞書の `lcid` を優先** — DB 未登録の語でも AzooKey 候補に即効

### `LcidRank` 定義（案）

`pos` 文字列ではなく **lcid レンジ** で定義する。根拠は `AzooKeyLcidMapper` / AzooKey `DicdataStore`（助詞 147…368、助動詞 369…554）。

| rank | lcid 帯 / 条件 | UI 上の `pos` 相当 | 例 |
|------|---------------|-------------------|-----|
| 0 | 1288–1293（固有名詞系） | proper_noun/* | 東京 |
| 1 | 1281–1296, 1314, 1297–1305 | noun, noun/suffix | 表示、設定 |
| 2 | 11–52（形容詞） | adjective | 難しい |
| 3 | 53–1280（動詞・活用形。名詞帯除く） | verb | 調べる(619)、調べて(625) |
| 4 | lcid 不明 | — | 辞書外フレーズ |
| 5 | 147–368（助詞） | particle | が(148) |
| 6 | 369–554（助動詞） | verb（表示上） | です(460) |
| — | 接続詞・感動詞リスト | other/conjunction 等 | しかし（`lcid` なし） |

接続詞・感動詞は `lcid` を持たない。blocklist は従来どおり `pos` 静的リスト or 出力文字列マッチで足りる（ランキング対象外）。

### 適用範囲（段階的）

| Phase | 対象 | リスク | 期待効果 |
|-------|------|--------|---------|
| **A** | AzooKey 辞書セクション内の `lcid` ソート | 低 | 辞書候補のノイズ削減。候補の `lcid` を直接使用 |
| **B** | 履歴のタイブレーカー（`score` 同値帯、`history.lcid` 使用） | 低 | `maxHighHistoryCount=3` の枠争いを改善 |
| **C** | 長文フレーズペナルティ（`output.count > 10` かつ `lcid IS NULL`） | 極低 | 辞書外フレーズ履歴のノイズ削減 |
| **D** | `history.lcid` 保存 + `pos` 表示タグ + backfill | — | **実装済み** |

**やらないこと**

- 履歴の主ソートを rank に置き換える
- `pos` 文字列での候補ソート（情報が粗すぎる）
- `lcid` 欠落語の一律非表示
- Zenzai top-1 プロモート行の rank による差し替え

## 実装ステップ

### Step 1: `LcidRank` ユーティリティ（`Core/`）— **未着手**

```swift
enum LcidRank: Int, Comparable, Sendable {
    case properNoun = 0
    case noun = 1
    case adjective = 2
    case verb = 3
    case unknown = 4
    case particle = 5
    case auxiliary = 6

    /// 候補・履歴の正本。AzooKey 接続 ID から rank を返す。
    static func from(lcid: Int?) -> LcidRank { ... }

    /// `lcid` 欠落時のフォールバックのみ。通常パスでは使わない。
    static func from(pos: String?) -> LcidRank { ... }
}
```

- lcid レンジ定義は `AzooKeyLcidMapper` と共有（二重管理を避けるため mapper に `rank(for lcid:)` を置くか、単一の lcid 定数ファイルに集約）
- テスト: `LcidRankTests`（619 vs 625 で verb 同 rank、1283 vs 1293 で properNoun vs noun 等）

### Step 2: AzooKey 候補の lcid ソート（Phase A）

`requestCandidates` 返却時に `Candidate` 配列から text→lcid マップを構築し、安定ソート:

```swift
candidates.sorted { a, b in
    let ra = LcidRank.from(lcid: lcidMap[a])
    let rb = LcidRank.from(lcid: lcidMap[b])
    if ra != rb { return ra < rb }
    return originalIndex(a) < originalIndex(b)
}
```

- Zenzai top-1（`azooKeyCandidates.first`）はソート前を維持
- `lcidForCommitted` の逐次ルックアップは使わない（N 回変換は重い）

### Step 3: 履歴タイブレーカー（Phase B）

`fetchHistoryScoredMerged` 結果を Swift 側で二次ソート。`history.lcid` を優先:

```swift
results.sorted {
    if $0.score != $1.score { return $0.score > $1.score }
    return LcidRank.from(lcid: $0.lcid) < LcidRank.from(lcid: $1.lcid)
}
```

- `lcid` が NULL の行は `LcidRank.unknown`（または `from(pos:)` フォールバック）
- スコア差が `epsilon`（例: 0.01）以内のときだけ rank で並べ替える制約も検討可

### Step 4: DB・表示基盤（Phase D）— **実装済み**

- `history.lcid INTEGER` 列 + schema v5 マイグレーション
- 確定時 / backfill で `pos`（表示）+ `lcid`（生 ID）を同時保存
- `AzooKeyLcidMapper` に verb / adjective / particle レンジ追加
- 設定画面: 品詞列（`pos`）+ `lcid` 列

### Step 5: 長文ペナルティ（Phase C、任意）

`lcid IS NULL` かつ `output.count > 10` を `LcidRank` 内で微減点。

## 変更ファイル（想定）

| ファイル | 変更内容 | 状態 |
|---------|---------|------|
| `AzooKeyLcidMapper.swift` | lcid レンジ + `pos` 派生 | 済 |
| `DatabaseManager.swift` / `+History.swift` | `lcid` 列、backfill | 済 |
| `HistoryViewController.swift` | `lcid` 列表示 | 済 |
| `LcidRank.swift`（新規） | lcid → rank（ロジック正本） | 未 |
| `AzooKeyConverter.swift` | 候補返却時 text→lcid マップ | 未 |
| `InputHandler+Candidates.swift` | AzooKey セクション内 lcid ソート | 未 |
| `DatabaseManager+History.swift` | 履歴タイブレーカー（`lcid` 使用） | 未 |
| `LcidRankTests.swift`（新規） | rank 変換テスト | 未 |

## 検証

### ユニットテスト

- 同一 rank 内は元の順序を維持（安定ソート）
- Zenzai top-1 はソート前 first を維持
- 履歴: スコア差が大きいとき `lcid` rank で順序が入れ替わらない
- 619（調べる）と 625（調べて）は同 verb rank、辞書形が先なら現状順維持でよい

### sandbox 手動確認（`/keynaco-ime-sandbox`）

| 読み | 確認点 |
|------|--------|
| `かんじ` | lcid 名詞帯の候補が動詞帯より上か |
| `きょう` | lcid 1293（地名）が助詞帯より上か |
| `しらべ` | 履歴「調べて」（lcid 625）がスコア優先で残るか |
| `ひょうじ` | lcid 1283 系が辞書候補の上位か |

## 関連 plan

| plan | 関係 |
|------|------|
| [`PLAN260525b-candidate-filter-prompt.md`](PLAN260525b-candidate-filter-prompt.md) | 履歴 blocklist 済み。本 plan は `lcid` 並び替え層 |
| [`PLAN260524-pos-tag-taxonomy.md`](PLAN260524-pos-tag-taxonomy.md) | `pos` 表示タグ体系（ロジックには使わない） |
| [`PLAN260519-candidate-section-declaration.md`](PLAN260519-candidate-section-declaration.md) | セクション構造。セクション**間**順序は変えない |

## 判断基準（POC 後）

| 結果 | 判断 |
|------|------|
| AzooKey セクションで名詞帯 lcid が上位に来る | Phase A をマージ |
| 履歴でよく使う動詞（lcid 625 等）が消える | Phase B を弱める or 撤回 |
| sandbox で体感改善なし | Phase A のみ留保、B/C は見送り |

## 実装順序

1. ~~Phase D（`lcid` 保存・`pos` 表示・backfill・設定 UI）~~ **完了**
2. `LcidRank` + テスト（lcid レンジ正本）
3. Phase A（AzooKey 候補の lcid ソート）→ sandbox 確認
4. Phase B（履歴タイブレーカー、`history.lcid` 使用）
5. Phase C（長文ペナルティ、任意）
