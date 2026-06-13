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
3. **AzooKey 辞書**（`azooKeyDict` セクション）: AzooKey/Zenzai の返却順のまま。`candidateCache` 内の `[Candidate].data[].lcid` は保持されるが、`requestCandidates` は `[String]` のみ返すため並び替えに未使用
4. **DB**: `history.pos`（表示用）+ `history.lcid`（ロジック用）を保存。設定画面に両列表示。`lcid` は `recordPrefixes` 同期ではなく `schedulePOSClassification` の非同期 Task で後追い保存（直後の候補では NULL の行があり得る）

## 実装ギャップ（コードレビュー追記 2026-06-13）

着手前に解消すべき API / データのずれ。Step 2・3 に反映済み。

| ギャップ | 現状 | 対応方針 |
|---------|------|---------|
| Phase A: `lcid` が API から落ちる | `AzooKeyConverter.candidateTexts` が `Candidate` → `String` に変換して捨てる | キャッシュ済み `[Candidate]` から text→lcid を構築する API を追加（下記 Step 2） |
| Phase A: 代表 `lcid` の選び方 | 複合語候補は末尾トークンが助詞のことがある | `lcidForCommitted` と同じ `primaryLcid(from:)`（助詞・EOS を除く最初の content 語）を使う |
| Phase B: `fetchHistoryScoredMerged` に `lcid` なし | 戻り値は `(output, score)` のみ | SQL で `lcid` を一緒に返す（`MAX(used_at)` 行の lcid 等）。N+1 の `lcidForOutput` は避ける |
| Phase B: 履歴 `lcid` の非同期 | 確定直後は `lcid IS NULL` のままのことがある | `from(pos:)` フォールバックは **NULL 行限定**。backfill 完了後は通常パスで `lcid` のみ |
| `LcidRank` と mapper の二重管理 | `AzooKeyLcidMapper` にレンジ定義あり | rank も mapper に集約（`rank(for:)`）。`LcidRank` enum は薄い Comparable ラッパーで可 |
| ソート適用位置 | `CandidateSectionBuilder` は `zenzaiPromoted` を先に抜く | `fetchAzooKeyCandidates` 直後（`InputHandler+Candidates`）。Zenzai はソート前の `first` を固定 |
| Phase B の実効箇所 | 全履歴行ではなく枠争い | 主に `maxHighHistoryCount=3` の 2 パス目（前方一致以外の highHistory 選別）に効く |

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
| **A** | AzooKey 辞書セクション内の `lcid` ソート | 低 | 辞書候補のノイズ削減。候補の `lcid` を直接使用 | **実装済み**（`4095039`） |
| **B** | 履歴のタイブレーカー（`score` 同値帯、`history.lcid` 使用） | 低 | `maxHighHistoryCount=3` の枠争いを改善 | **実装済み** |
| **C** | 長文フレーズペナルティ（`output.count > 10` かつ `lcid IS NULL`） | 極低 | 辞書外フレーズ履歴のノイズ削減 |
| **D** | `history.lcid` 保存 + `pos` 表示タグ + backfill | — | **実装済み** |

**やらないこと**

- 履歴の主ソートを rank に置き換える
- `pos` 文字列での候補ソート（情報が粗すぎる）
- `lcid` 欠落語の一律非表示
- Zenzai top-1 プロモート行の rank による差し替え

## 実装ステップ

### Step 1: `LcidRank` ユーティリティ（`Core/`）— **実装済み**（`50efb07`）

**正本は `AzooKeyLcidMapper.rank(for:)`**。レンジ定義は mapper に集約し、二重管理を避ける。`LcidRank` enum は Comparable ラッパーとして薄く置くか、mapper が `LcidRank` を直接返してもよい。

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

- テスト: `AzooKeyLcidMapperTests` に rank ケースを追加（619 vs 625 で verb 同 rank、1283 vs 1293 で properNoun vs noun、460 で auxiliary・148 で particle 等）

### Step 2: AzooKey 候補の lcid ソート（Phase A）— **実装済み**（`4095039`）

#### 2a. API 拡張（`AzooKeyConverter` / `AzooKeyConverting`）

現状 `requestCandidates` → `[String]` だけでは lcid が届かない。`candidateCache` の `[Candidate]` からマップを構築して返す。

```swift
// 案: requestCandidates の直後にキャッシュから引く（変換は再実行しない）
func primaryLcidByText(
    hiragana: String, leftSideContext: String?, richCandidates: Bool
) -> [String: Int]
```

- 各 `Candidate` について `AzooKeyConverter.primaryLcid(from: candidate.data)` で代表 lcid を決める（`lcidForCommitted` と同一ロジック）
- `filterCandidatesForDisplay` 適用後のテキスト列とマップのキーを揃える
- プロトコル `AzooKeyConverting` とスタブ（`BaseAzooKeyStub`・各テスト mock）も更新

#### 2b. ソート（`InputHandler+Candidates.fetchAzooKeyCandidates` 直後）

```swift
candidates.sorted { a, b in
    let ra = LcidRank.from(lcid: lcidMap[a])
    let rb = LcidRank.from(lcid: lcidMap[b])
    if ra != rb { return ra < rb }
    return originalIndex(a) < originalIndex(b)
}
```

- **Zenzai top-1**（`makeCandidateListSources` 内の `azooKeyCandidates.first`）はソート**前**の配列から決める（現行フロー維持）
- `lcidForCommitted` の逐次ルックアップは使わない（N 回変換は重い）
- `CandidateSectionBuilder` 側は変更不要（ソート済み `[String]` を渡すだけ）

### Step 3: 履歴タイブレーカー（Phase B）

#### 3a. API 拡張（`fetchHistoryScoredMerged`）

戻り値に `lcid` を含める（N+1 回避）:

```swift
func fetchHistoryScoredMerged(reading: String) -> [(output: String, score: Double, lcid: Int?)]
```

SQL 例（`GROUP BY output` 維持）:

```sql
SELECT output, SUM(...) AS s,
       (SELECT lcid FROM history h2
        WHERE h2.output = history.output AND h2.lcid IS NOT NULL
        ORDER BY used_at DESC LIMIT 1) AS lcid
...
ORDER BY s DESC, MAX(used_at) DESC
```

（サブクエリの代わりに `MAX(used_at)` と同じ行の lcid を取る実装でも可。要: output ごとに代表 lcid が 1 つ）

#### 3b. 二次ソート（`collectCheapCandidateSources` 内、または `fetchHistoryScoredMerged` 直後）

```swift
results.sorted {
    if abs($0.score - $1.score) > epsilon { return $0.score > $1.score }
    let ra = rankForHistoryRow($0)  // lcid 優先、NULL 時のみ pos フォールバック（任意）
    let rb = rankForHistoryRow($1)
    if ra != rb { return ra < rb }
    return $0.score > $1.score
}
```

- **`epsilon = 0.01` を採用**（スコア差が明確なときは rank で入れ替えない）
- `lcid` が NULL の行は `LcidRank.unknown`。`pos` フォールバックは **NULL 行に限定**し、必要なら `posForOutput` で引く（戻り値 tuple に `pos` を載せない設計でも可）
- 確定直後は `pos` / `lcid` とも NULL のことがある → その間はタイブレーカー無効（`unknown` 同士）
- 実効箇所: `maxHighHistoryCount=3` の枠争い（exact 一致枠は別パスで先に埋まる）

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
| `AzooKeyLcidMapper.swift` | lcid レンジ + `pos` 派生 + `rank(for:)` | 済 |
| `DatabaseManager.swift` / `+History.swift` | `lcid` 列、backfill | 済 |
| `HistoryViewController.swift` | `lcid` 列表示 | 済 |
| `LcidRank.swift` | Comparable ラッパー + `from(lcid:)` / `from(pos:)` | 済 |
| `AzooKeyConverter.swift` | `primaryLcidByText`（キャッシュから text→lcid） | 済 |
| `AzooKeyConverting.swift` | プロトコルに `primaryLcidByText` 追加 | 済 |
| `BaseAzooKeyStub.swift` 等 | テストスタブ更新 | 済 |
| `InputHandler+Candidates.swift` | `fetchAzooKeyCandidates` 直後の lcid ソート | 済 |
| `InputHandlerAzooKeyLcidSortTests.swift` | ソート・Zenzai 先頭固定テスト | 済 |
| `AzooKeyLcidMapperTests.swift` | rank 変換テスト | 済 |
| `DatabaseManager+History.swift` | `fetchHistoryScoredMerged` に `lcid` + epsilon タイブレーカー | 済 |

## 検証

### ユニットテスト

- 同一 rank 内は元の順序を維持（安定ソート）
- Zenzai top-1 はソート前 first を維持
- 履歴: スコア差が `epsilon` 超のとき `lcid` rank で順序が入れ替わらない
- 履歴: スコア差が `epsilon` 以内のときのみ rank で枠（`maxHighHistoryCount`）が変わる
- 619（調べる）と 625（調べて）は同 verb rank、辞書形が先なら現状順維持でよい
- 460（です）→ `auxiliary` rank、148（が）→ `particle` rank（助動詞は表示 `pos` が verb でも rank は分離）

### sandbox 手動確認（`/keynaco-ime-sandbox`）

| 読み | 確認点 |
|------|--------|
| `かんじ` | lcid 名詞帯の候補が動詞帯より上か |
| `きょう` | lcid 1293（地名）が助詞帯より上か（※ `kyou` は日付変換の罠。`toukyou` で代替可） |
| `しらべ` | 履歴「調べて」（lcid 625）がスコア優先で残るか（Phase B 後） |
| `ひょうじ` | lcid 1283 系が辞書候補の上位か |

#### Phase A sandbox 結果（2026-06-13）

環境: Debug ビルド `4095039`（初回は `ef2aed0` が走っており stale → 再ビルド・再起動後に検証）。コマンドは `{"reset":true}` → `{"type_string":"<romaji>","then":"space"}`。

| 読み | 辞書セクション先頭（`candidates` 先頭付近） | 判定 | メモ |
|------|---------------------------------------------|------|------|
| `hyouji` | `ヒョウジ`, `ひょうじ`, `兵司`, `表情`, `標準`, `表示`, … | ✅ | `AzooKeyConverter` の lcid ソート後順序と **完全一致** |
| `toukyou` | `東京都`, `東京市`, `東京`, `東京府`, … | ✅ | 固有名詞帯（lcid 1293 等）が先頭。`きょう` の代替 |
| `kanzi` | `完治`, `カンジ`, `寛治`, …, `感じ`, `漢字`, … | ✅ | 固有名詞帯が名詞帯（感じ・漢字）より前。AzooKey 生順（`感じ` 先頭）とは異なりソート生效 |

**観察メモ**

- `感じ` / `漢字` はいずれも lcid 1285（noun rank）→ 安定ソートで API 返却順を維持（`感じ` → `漢字`）。名詞 vs 動詞の分離テストには不向き
- `完治` / `カンジ` は同 rank（properNoun）内の順序はキャッシュ時の生順に依存（インスタンス間で入れ替わり得る）
- ユニットテスト: `InputHandlerAzooKeyLcidSortTests`（4件）・`InputHandlerZenzaiPromoteTests`（既存4件）パス

**Phase A 判断**: sandbox で体感改善あり → 判断基準どおり **Phase A は採用**。次は Phase B。

## 関連 plan

| plan | 関係 |
|------|------|
| [`PLAN260525b-candidate-filter-prompt.md`](PLAN260525b-candidate-filter-prompt.md) | 履歴 blocklist 済み。本 plan は `lcid` 並び替え層 |
| [`PLAN260524-pos-tag-taxonomy.md`](PLAN260524-pos-tag-taxonomy.md) | `pos` 表示タグ体系（ロジックには使わない） |
| [`PLAN260519-candidate-section-declaration.md`](PLAN260519-candidate-section-declaration.md) | セクション構造。セクション**間**順序は変えない |

## 判断基準（POC 後）

| 結果 | 判断 |
|------|------|
| AzooKey セクションで名詞帯 lcid が上位に来る | Phase A をマージ — **2026-06-13 sandbox で確認済み** |
| 履歴でよく使う動詞（lcid 625 等）が消える | Phase B を弱める or 撤回 |
| sandbox で体感改善なし | Phase A のみ留保、B/C は見送り |

## 実装順序

1. ~~Phase D（`lcid` 保存・`pos` 表示・backfill・設定 UI）~~ **完了**
2. ~~`LcidRank` + テスト（lcid レンジ正本）~~ **完了**（`50efb07`）
3. ~~Phase A（AzooKey 候補の lcid ソート）~~ **完了**（`4095039`）— sandbox 確認済み（上記）
4. ~~Phase B（履歴タイブレーカー、`history.lcid` 使用）~~ **完了**
5. Phase C（長文ペナルティ、任意）
