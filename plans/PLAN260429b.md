# PLAN260429b: G-1（セクション区切り）確認 + H-1（DB 自動 GC）実装

## 概要

IDEA260429 の「即投入」枠。

| アイデア | 状況 | 作業 |
|---------|------|------|
| G-1 候補ウィンドウ セクション区切り | **実装済み** | 動作確認のみ |
| H-1 DB 自動 GC | 未実装 | 実装 |

---

## G-1 現状確認

`CandidateWindow.swift` を読んだ結果、**G-1 はすでに完全実装済み**。

### 実装済み要素

| 要素 | ファイル・行 | 内容 |
|------|------------|------|
| `sectionLabel` | `CandidateWindow.swift:13, 46–49` | `NSTextField(labelWithString: "")`, 9pt グレー文字 |
| `sectionDivider` | `CandidateWindow.swift:12, 41–44` | `NSView` 1.5px、`controlAccentColor` 0.4 alpha、行下端 |
| ラベル表示ロジック | `CandidateWindow.swift:245–252` | 各セクション先頭行（`fixedRowCount`, `predictionSectionEnd`, `historySectionEnd`）に "予測" / "履歴" / "辞書" を設定 |
| 区切り線表示ロジック | `CandidateWindow.swift:254–256` | 予測・履歴の末尾行の下端に線を描画 |

IDEA260429 が描いた「セクションラベル＋区切り線」の設計はそのまま実現されている。
**本 PLAN では G-1 を「済み」として追加実装なし**。動作確認だけ行う。

### 確認ポイント

1. 履歴+辞書候補が混在するときに "予測" / "履歴" / "辞書" ラベルが各セクション先頭に表示される
2. セクション境界行の下端に区切り線が表示される
3. Shift+Delete ボタンが "履歴" セクションのみに出る

---

## H-1 DB 自動 GC 実装

### 目的

長期使用で `history` / `bigram` / `trigram` / `skip_bigram` テーブルに
`count = 1` の古いエントリが蓄積するのを定期的に刈り込む。

### 設計

#### GC 条件

```sql
-- 4テーブル共通パターン
DELETE FROM history     WHERE count = 1 AND used_at < :cutoff;
DELETE FROM bigram      WHERE count = 1 AND used_at < :cutoff;
DELETE FROM trigram     WHERE count = 1 AND used_at < :cutoff;
DELETE FROM skip_bigram WHERE count = 1 AND used_at < :cutoff;
VACUUM;
```

- `cutoff` = 現在時刻 − 180日（15,552,000秒）
- `count = 1` のみ対象：複数回使った変換は残す
- 7日間に1回だけ実行（UserDefaults でガード）

#### `DatabaseManager` への追加

`DatabaseManager.swift` に `performGCIfNeeded()` メソッドを追加。

```swift
func performGCIfNeeded() {
    let key = "lastGCDate"
    let defaults = UserDefaults.standard
    let now = nowEpoch()
    if let lastEpoch = defaults.object(forKey: key) as? Int64,
       now - lastEpoch < 7 * 86400 { return }

    let cutoff = now - 180 * 86400
    let tables = ["history", "bigram", "trigram", "skip_bigram"]
    for table in tables {
        execute("DELETE FROM \(table) WHERE count = 1 AND used_at < ?") { stmt in
            sqlite3_bind_int64(stmt, 1, cutoff)
        }
    }
    sqlite3_exec(db, "VACUUM;", nil, nil, nil)
    defaults.set(now, forKey: key)
    NSLog("keynaco: DB GC 完了")
}
```

- 時刻は `nowEpoch()`（`clock` var 経由）で取得する。`Date()` を直接使うと `clock` を差し替えるテストと矛盾するため使用しない。
- `lastGCDate` は `Int64` epoch として保存・比較する（`Date` 型にしない）。
- `execute` は既存のプライベートヘルパーをそのまま利用（`DatabaseManager.swift` 内に定義済み）。

#### `AppDelegate` への呼び出し追加

`applicationDidFinishLaunching` の末尾で非同期呼び出し。

```swift
Task.detached(priority: .background) {
    DatabaseManager.shared.performGCIfNeeded()
}
```

起動時の UI ブロックを避けるため `Task.detached` + `.background` priority で実行。

### 変更ファイル

| ファイル | 変更内容 |
|---------|---------|
| `Sources/DatabaseManager.swift` | `performGCIfNeeded()` を追加（`// MARK: - GC` セクション） |
| `Sources/AppDelegate.swift` | `applicationDidFinishLaunching` 末尾に `Task.detached` 呼び出しを追加 |

### テスト方針

`DatabaseManagerTests.swift`（既存）に以下を追加：

- `count=1` かつ `used_at` が 180日以上前のエントリが削除されること
- `count=2` のエントリは残ること
- `count=1` でも `used_at` が 90日前（新しい）のエントリは残ること
- 7日以内は再実行しないこと（`clock` を固定値に差し替え、`UserDefaults.standard.set(now - 3 * 86400, forKey: "lastGCDate")` をセットしてから呼ぶ）
- `tearDown` で `UserDefaults.standard.removeObject(forKey: "lastGCDate")` を呼んで他テストへの汚染を防ぐ

### 規模見積もり

2〜3時間（実装 1h＋テスト 1h＋動作確認）。

---

## 実装手順

1. `DatabaseManager.swift` に `performGCIfNeeded()` を追加
2. `AppDelegate.swift` に `Task.detached` 呼び出しを追加
3. テスト追加・実行（`xcodebuild test -scheme keynaco -destination "platform=macOS"`）
4. `/deploy` でビルド＆インストール、実機動作確認
5. G-1 の表示確認（セクションラベル・区切り線・Shift+Delete ボタン範囲）
6. コミット
