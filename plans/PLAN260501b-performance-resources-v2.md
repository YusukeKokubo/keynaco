# PLAN260501b: パフォーマンス・リソース節約（第2弾）

## 概要

PLAN260501（A〜E）実装後の次フェーズ改善。
DB 書き込みコスト削減・候補ウィンドウ描画効率化・SQLite 設定最適化が主な対象。

---

## 改善一覧

| # | 内容 | 変更量 | 優先度 | レビュー |
|---|------|--------|--------|---------|
| F | SQLite PRAGMA（WAL + NORMAL）を明示設定 | 極小 | P0 | ✅ 実装箇所を `openDatabase()` 内に |
| G | デバッグ用 `NSLog` を `#if DEBUG` で囲む | 極小 | P0 | ✅ なし |
| H | `commitText` 内の DB 書き込みをトランザクションでまとめる | 小 | P1 | ⚠️ 変数名修正・トランザクション境界の検討 |
| I | `recordPrefixes` をバッチ INSERT に変更 | 小 | P1 | ⚠️ 「count リセット」前提を削除して再定義 |
| J | `reloadData()` を差分更新（`reloadRows`）に変更 | 中 | P2 | ✅ 後回しのまま |
| K | セグメント境界調整時の再クエリを差分に絞る | 中 | P2 | ⚠️ キャッシュクリアを3箇所に追記 |

---

## F. SQLite PRAGMA を明示設定

**ファイル**: `Sources/DatabaseManager.swift`

### 問題

`journal_mode` と `synchronous` が SQLite デフォルト（`DELETE` / `FULL`）のまま。
WAL モードに切り替えると読み取りと書き込みが並行できるため、キー入力レイテンシが下がる。

### 実装方針

`openDatabase()` 関数内、`sqlite3_open` 成功直後に追加する。
`init(inMemory: Bool)` はこの関数を呼ばないため、WAL はファイル DB のみに適用される。

```swift
// openDatabase() 内、sqlite3_open 成功後
sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
sqlite3_exec(db, "PRAGMA cache_size = -4096;", nil, nil, nil)  // 4 MB
```

`synchronous = NORMAL` は WAL モードでは crash-safe を維持したまま `FULL` より高速。

---

## G. デバッグ用 `NSLog` を `#if DEBUG` で囲む

**ファイル**: `Sources/DatabaseManager.swift`, `Sources/AppDelegate.swift`

### 問題

本番ビルドでも GC 完了ログ等が流れ続ける。
ただし全 NSLog を囲むのは粗い。エラー条件のログは本番でも診断に使えるため残す。

### 対象箇所の分類

| ファイル | ログ内容 | 判断 |
|---------|---------|------|
| `AppDelegate.swift:18` | `InputMethodConnectionName not found` | エラー → **残す** |
| `AppDelegate.swift:22` | `IMKServer started` | デバッグ → `#if DEBUG` |
| `DatabaseManager.swift:41` | `DB を開けませんでした` | エラー → **残す** |
| `DatabaseManager.swift:44` | `DB パス =` | デバッグ → `#if DEBUG` |
| `DatabaseManager.swift:585` | `DB GC 完了` | デバッグ → `#if DEBUG` |

### 実装方針

デバッグログのみを囲む。エラーログはそのまま残す。

```swift
// デバッグログのみ囲む例
#if DEBUG
NSLog("keynaco: IMKServer started")
#endif

// エラーログは残す
NSLog("keynaco: DB を開けませんでした: \(path)")
```

XcodeGen はデフォルトで Debug 設定に `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` を生成するため、
`#if DEBUG` はそのまま動く。`project.yml` への追記は不要。

---

## H. `commitText` 内の DB 書き込みをトランザクションでまとめる

**ファイル**: `Sources/DatabaseManager.swift`, `Sources/InputHandler.swift`

### 問題

`commitText()` 内で `recordBigram` / `recordTrigram` / `recordSkipBigram` / `record()` が
個別に呼ばれ、それぞれが独立した SQLite トランザクションになっている。
1回の確定で 3〜5 回のコミットが発生する。

### 実装方針

`DatabaseManager` にトランザクション制御を追加する。

```swift
// DatabaseManager.swift に追加
func withTransaction(_ body: () -> Void) {
    execute("BEGIN") { _ in }
    body()
    execute("COMMIT") { _ in }
}
```

`InputHandler.commitText()` の DB 書き込みをまとめる。

```swift
db.withTransaction {
    db.record(input: reading, output: text)
    if let prev = lastCommittedOutput {
        // 実際のシグネチャ: recordBigram(prev: String, input: String, output: String)
        db.recordBigram(prev: prev, input: reading, output: text)
        if let prev2 = prev2Output {  // ※ prevPrevCommittedOutput ではなく prev2Output（InputHandler.swift:75）
            db.recordTrigram(prev2: prev2, prev1: prev, input: reading, output: text)
        }
        if let skipPrev = mostRecentContentWord, skipPrev != prev {
            db.recordSkipBigram(prev: skipPrev, input: reading, output: text)
        }
    }
}
```

現状は `throws` を使っていないため、まず ROLLBACK なしの単純版で実装する。
実装時は `DatabaseManager.swift:272` 付近の実際のシグネチャを再確認すること。

**トランザクション境界の注意**: `recordPrefixes()` は `commitText()` の呼び出し元（`InputHandler.swift:209/215/225/229`）で呼ばれるため、`commitText()` 内に `withTransaction` をラップしても `recordPrefixes()` はトランザクション外に残る。
全書き込みをまとめるには呼び出し元側でトランザクションを開く必要がある。
まずは `commitText()` 内の bigram/trigram/skipBigram 3コミットを1つにまとめる範囲で実装し、効果を測ってから拡張を検討する。

---

## I. `recordPrefixes` をバッチ INSERT に変更

**ファイル**: `Sources/DatabaseManager.swift`

### 問題

`recordPrefixes(reading:output:)` が読みの長さ N に対して N-1 回の DB 往復が発生する。
5文字の読みなら 4 回の INSERT が個別に実行される。

現状：
```swift
for i in stride(from: 2, through: reading.count, by: 1) {
    let prefix = String(reading.prefix(i))
    record(input: prefix, output: output)
}
```

**注意**: 現在の `record()` はすでに `ON CONFLICT(input, output) DO UPDATE SET count = count + 1`
（`DatabaseManager.swift:462`）を使っており、`count` は正しく蓄積されている。
「count がリセットされる」という問題はなく、改善の目的は純粋に **DB 往復回数の削減**。

### 実装方針

VALUES 句を動的に構築してバッチ INSERT に変更する。
`ON CONFLICT DO UPDATE` で `count` 蓄積を維持する。

```swift
func recordPrefixes(reading: String, output: String) {
    let chars = Array(reading)
    guard chars.count >= 3 else { return }  // 現コード（DatabaseManager.swift:479）に合わせる
    let now = nowEpoch()
    let prefixes = (2...chars.count).map { String(chars.prefix($0)) }
    let placeholders = prefixes.map { _ in "(?,?,?,?)" }.joined(separator: ",")
    let sql = """
        INSERT INTO history (input, output, count, used_at)
        VALUES \(placeholders)
        ON CONFLICT(input, output) DO UPDATE SET
            count   = count + 1,
            used_at = excluded.used_at;
        """
    // バインド: (prefix, output, 1, now) を prefixes.count 分
}
```

既存の `execute` ヘルパーが単一バインドを想定しているため、
バッチ用の `executeBatch` を別途追加する。

---

## J. `reloadData()` を差分更新に変更 ※後回し

**ファイル**: `Sources/CandidateWindow.swift`

### 問題

候補リストが更新されるたびに `tableView.reloadData()` が呼ばれ、全セルを再生成する。

### 効果が限定的な理由（レビュー指摘）

- 候補数が変わる場合（= ほとんどのキー操作）は `reloadData()` にフォールバックするため恩恵は小さい
- テキストが同じでも `isHistory` 背景色・セクションラベル・削除ボタン表示状態が変わる場合があり、テキスト差分だけでは不十分
- NSTableView はセル再利用（`makeView(withIdentifier:)`）をしているので、10〜20行程度の `reloadData()` は元から安い

### 実装するなら

テキストだけでなく行メタデータ（`isHistory` / `sectionLabel` / 削除可否）を含む差分比較が必要。
優先度 P2 のまま後回しでよい。

---

## K. セグメント境界調整時の再クエリを差分に絞る

**ファイル**: `Sources/InputHandler+SegmentMode.swift`

### 問題

Shift+矢印でセグメント境界を 1 文字動かすたびに `buildSegmentCandidates()` が
全セグメント分の `fetchHistoryExact` + `fetchBigram` を実行する。

### キー設計の誤り（レビュー指摘）

`reading` だけをキーにすると `prev`（前セグメントの出力）への依存を無視することになる。
`buildSegmentCandidates(reading:dictCandidates:prev:)` は `prev` が違えばバイグラム候補が変わる
（`InputHandler+SegmentMode.swift:69`）ため、`reading` のみのキーでは誤った候補を返す。

また実際の戻り型は `[String]` ではなく `Segment` struct。

### 修正後の実装方針

```swift
// InputHandler に追加
// キー: "reading|prev"（prev が nil の場合は "reading|"）
private var segmentCandidateCache: [String: Segment] = [:]

// buildSegmentCandidates() 内
let cacheKey = "\(reading)|\(prev ?? "")"
if let cached = segmentCandidateCache[cacheKey] {
    return cached
}
let result: Segment = /* DB クエリ + AzooKey */
segmentCandidateCache[cacheKey] = result
return result
```

**キャッシュのクリア**: `exitSegmentMode` 関数は存在しない。
`state.segmentState = nil` の代入が3箇所に散在しているため、それぞれに `segmentCandidateCache.removeAll()` を追加する。

```swift
// InputHandler+SegmentMode.swift（行138付近）
state.segmentState = nil
segmentCandidateCache.removeAll()

// 同（行144付近）
state.segmentState = nil
segmentCandidateCache.removeAll()

// 同（行149付近）
state.segmentState = nil
segmentCandidateCache.removeAll()
```

実装前に `buildSegmentCandidates` の実際のシグネチャと行番号を再確認すること。

---

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `Sources/DatabaseManager.swift` | PRAGMA 設定・トランザクション制御・バッチ INSERT・NSLog 除去 |
| `Sources/AppDelegate.swift` | NSLog を `#if DEBUG` で囲む |
| `Sources/InputHandler.swift` | `commitText` でトランザクション呼び出し |
| `Sources/CandidateWindow.swift` | 差分 `reloadRows` |
| `Sources/InputHandler+SegmentMode.swift` | セグメント候補キャッシュ |

---

## テスト方針

- F・G: ロジック変更なし → 既存テストが通れば OK
- H: `withTransaction` の単純版（BEGIN/COMMIT のみ）で実装。既存テストが通ることで確認
- I: バッチ INSERT 後も同じ候補が返ることを `inMemory: true` の DB でテスト
- J: 候補リストの順序・内容が変わらないことを手動確認（MockCandidateWindow がないため）
- K: セグメント調整テストでキャッシュが正しくクリアされることを確認

---

## 規模見積もり

3〜4時間（F: 15分, G: 15分, H: 45分, I: 45分, J: 60分, K: 60分）。
F・G は即日でも対応可能。H・I はセットで実装すると効率が良い。
