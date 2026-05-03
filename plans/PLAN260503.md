# PLAN260503: IME 品質抜本改善

冷スタート体験・境界学習・セグメント候補・skip-bigram 多ホップの4本柱。

---

## 実装状況（このドキュメントの追記）

最終メンテ: 2026-05-03（コードベース照合）

| 項目 | 状態 | メモ |
|------|------|------|
| **P1** プリセット bi-gram | **済** | `DatabaseManager`: `is_preset`・初回 seed（`preset_bigram.csv`・`preset_seeded_v1`）・`fetchBigramTopCount` / `replaceBigram` / GC の3修正。出典は [`docs/domain/glossary.md`](../docs/domain/glossary.md)「プリセット bi-gram」。 |
| **P2** boundary_pref 前方一致 | **済** | `saveBoundaryPref`: `fullReading.count >= 4`。`fetchBoundaryPref`: `WHERE ? LIKE full_reading \|\| '%'` + `ORDER BY length` DESC。 |
| **P3** セグメント + prefix 履歴 | **済** | [`Sources/InputHandler+SegmentMode.swift`](../Sources/InputHandler+SegmentMode.swift) `buildSegmentCandidates`: `fetchHistoryExact` + `fetchHistoryPrefix` を `merged`。 |
| **P4** AzooKey と履歴スコア | **済** | [`InputHandler+Candidates.swift`](../Sources/InputHandler+Candidates.swift) `historyRecencyScoreCutoff = 0.5` で high/low 分割。`historyEnd` は高スコアのみ。低スコアはリスト末尾へ（[`glossary.md`](../docs/domain/glossary.md)「候補優先順位」）。 |
| **P5** ステータスバー（Successor 保留） | **済** | `Notification.Name.keynacoSuccessorPendingChanged`・[`AppDelegate`](../Sources/AppDelegate.swift) の `NSStatusItem`（`⌨` / `⌨…`）・[`InputController`](../Sources/InputController.swift) から通知。 |
| **P6** skip-bigram 多ホップ | **未** | `commitText` / `suggestSuccessors` / `buildCandidateList` / `buildPendingCandidateList` はいまだ `mostRecentContentWord()` のみ（`mostRecentContentWords(n:)` 未導入）。 |
| **P7** 候補の読み表示 | **未** | `CandidateWindow` にふりがなサブテキストなし。AzooKey API 調査・実装とも未。 |

**残タスク（優先の目安）**: P6 → P7（P4 の前提 API 確認は、現状ロジックで満たしているなら不要）。

---

## P1: プリセット bi-gram バンドル（最優先）

### 目的
新規インストール直後から Successor モード・pendingRomaji 先読み・bi-gram 予測が動くようにする。

### スキーマ変更
```sql
ALTER TABLE bigram ADD COLUMN is_preset INTEGER NOT NULL DEFAULT 0;
```

`createTables` に `IF NOT EXISTS` で追加する。既存 DB へは `openDatabase` 後に
`ALTER TABLE bigram ADD COLUMN is_preset INTEGER NOT NULL DEFAULT 0`
を試行（既に存在する場合は無視）。

### seed タイミング
`openDatabase` 完了後、`UserDefaults` の `preset_seeded_v1` フラグが未セットのときのみ実行。
プリセット行は `is_preset = 1, count = 5（= successorImmediateThreshold）` で INSERT OR IGNORE。

### データ
日本語の汎用連語（数千エントリ）。ライセンス・出典を `docs/domain/glossary.md` の
「学習・履歴」セクションに追記。形式は `(prev, input, output)` の CSV をソースに持ち、
`DatabaseManager` の seed メソッドで投入。

### 修正が必要な箇所（3点）

#### (a) `fetchBigramTopCount`（Sources/DatabaseManager.swift L327–338）
プリセット行は `used_at` が古くなると 90 日条件から外れ、即時表示閾値に反映されなくなる。
```sql
-- 変更前
SELECT MAX(count) FROM bigram WHERE prev = ? AND used_at > ?
-- 変更後
SELECT MAX(count) FROM bigram WHERE prev = ? AND (used_at > ? OR is_preset = 1)
```

#### (b) `replaceBigram`（Sources/DatabaseManager.swift L262）
Bi-gram インポート時の全削除がプリセット行を消す。
```swift
// 変更前
sqlite3_exec(db, "DELETE FROM bigram", nil, nil, nil)
// 変更後
execute("DELETE FROM bigram WHERE is_preset = 0")
```

#### (c) `performGCIfNeeded`（GC 対象から除外）
```sql
-- bigram の GC 条件に追加
AND is_preset = 0
```

### ON CONFLICT の扱い
`recordBigram` の `ON CONFLICT DO UPDATE SET count = count + 1, used_at = ...` は `is_preset` を
更新しない。プリセット行にユーザー学習が乗っても `is_preset = 1` のまま GC されない（意図した動作）。

---

## P2: `boundary_pref` 前方一致汎化

### 目的
「きょうはよいてんきです」を学習したとき「きょうはさむいですね」入力にも境界を再利用する。

### 保存側ガード
`saveBoundaryPref` 内で `full_reading.count < 4` のとき早期 return（呼び出し元を網羅せず一律）。

### `fetchBoundaryPref` SQL
```sql
-- 変更前
SELECT boundaries FROM boundary_pref WHERE full_reading = ?
-- 変更後
SELECT boundaries FROM boundary_pref
WHERE ? LIKE full_reading || '%'
ORDER BY length(full_reading) DESC
LIMIT 1
```
`?` には入力のフル読みをバインドする（入力が保存キーで始まる条件）。
`length(full_reading) >= 4` は保存時ガードで保証されるため SELECT 側フィルタ不要。

### テストで固定すべきケース
| 入力 | 保存キー | 期待 |
|------|---------|------|
| `きょうはさむい` | `きょうは` | ヒット |
| `きょうはよいてんきです` | `きょうはよいてんきです` | 完全一致ヒット（より長い方優先） |
| `きょう` | `きょうは` | ミス（入力が保存キーで始まらない） |
| `きょ` | `きょ`（3文字未満なので保存されない） | ミス |

---

## P3: セグメント候補に `fetchHistoryPrefix` 追加

### 現状
`buildSegmentCandidates`（Sources/InputHandler+SegmentMode.swift）はすでに:
- `fetchHistoryExact` → `historyCandidates`
- `fetchBigram` → `bigramCount`
を含み、`historyEnd = fixedCount + bigramCount + historyCandidates.count` で非ゼロ。

### 追加
`fetchHistoryPrefix` の結果を `fetchHistoryExact` とマージして `historyCandidates` に含める:
```swift
let exactCandidates = db.fetchHistoryExact(reading: reading)
let prefixCandidates = db.fetchHistoryPrefix(reading: reading)
let historyCandidates = InputHandler.merged(exactCandidates, prefixCandidates)
```
`historyEnd` の計算式は変えない（`historyCandidates.count` が増えるだけ）。
`fixedEnd: 0` は維持（セグメントの Shift+Delete は対象外）。

---

## P4: AzooKey と履歴スコアのインターリーブ（保守的アプローチ）

### 前提確認
`requestCandidates` の返り順が内部状態・バージョンで変動しないか確認してから実装。

### 方針
「低スコア履歴を AzooKey の先頭と差し替え」ではなく、
**score < 0.5 の履歴エントリを `historyEnd` から外し AzooKey セクションの後ろに移動**する。
高スコア履歴は現状どおり AzooKey より前。

---

## P5: Successor 待機中のフィードバック（ステータスバーアイコン）

`AppDelegate` の `NSStatusItem` を変更:
- 通常: `⌨`（現状アイコン）
- `pendingSuccessorCandidates` 非空: `⌨…`（または別 tiff）

`InputController` → `AppDelegate` への通知手段を決める（通知センター or 静的フラグ）。
Ghost Text との競合なし（役割が異なる）。

---

## P6: skip-bigram 多ホップ

### 現状
`commitText`（Sources/InputHandler.swift L246–248）:
```swift
if InputHandler.particles.contains(p1), let prevContent = mostRecentContentWord() {
    db.recordSkipBigram(prev: prevContent, input: state.finalizedText, output: text)
}
```
1語のみ。

### 変更

#### 記録側
```swift
if InputHandler.particles.contains(p1) {
    for cw in mostRecentContentWords(n: 2) {
        db.recordSkipBigram(prev: cw, input: state.finalizedText, output: text)
    }
}
```

#### `mostRecentContentWords(n:)` 新メソッド
`committedHistory` の末尾から逆順に非助詞語を最大 N 件返す（既存 `mostRecentContentWord()` は `n=1` の特殊ケースとして残すか委譲）。

#### 検索側（`suggestSuccessors`）
```swift
let skipBigramTop = mostRecentContentWords(n: 2)
    .flatMap { db.fetchSkipBigramTop(prev: $0) }
// → InputHandler.merged で重複排除
let skipBigramTop = InputHandler.merged(skipBigramTop)
```
同じ `output` が複数 `prev` から来た場合は `merged` の先着優先。

---

## P7: 候補ウィンドウの読み（ふりがな）表示

AzooKey の `requestCandidates` が読みを返せるか API を先に確認。
返せる場合: 候補データに reading を付与して `CandidateWindow` の行に薄いサブテキストで表示。
返せない場合: `composedHiragana` との prefix 推定で代用し、同音異表記は `—` でフォールバック。

---

## 実装順（当初計画）

| 順 | 項目 | 工数目安 | 実装 |
|----|------|---------|------|
| 1 | P1: プリセット bi-gram | 2–3日（データ収集含む） | 済 |
| 2 | P2: boundary_pref 前方一致 | 半日 | 済 |
| 3 | P3: セグメント候補に prefix 追加 | 半日 | 済 |
| 4 | P5: ステータスバーアイコン | 半日 | 済 |
| 5 | P6: skip-bigram 多ホップ | 1日 | **未** |
| 6 | P4: AzooKey インターリーブ | 1日（前提確認後） | 済 |
| 7 | P7: 読み表示 | 1–2日（API 確認後） | **未** |

当初の「実装順」と実際の着手順は一致していない（例: P5 が先に完了）。残りは **P6・P7**。
