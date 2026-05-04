# デバッグサンドボックスをリアル環境に近づける

## 目的

`DebugSocketServer` が使う `InputHandler` はインメモリ DB（空）を持つため、
Successor モードの preset bi-gram が効かず、変換履歴・ユーザー辞書・境界学習も存在しない。
以下の 2 施策でサンドボックスとリアル環境の差を縮める。

---

## 施策 1: Preset bi-gram シード

### 概要

`reset` コマンドで作る DB に `preset_bigram.csv` を投入する。
Successor モードで助詞・共起語の候補が本番と同じ水準で出るようになる。

### 変更ファイル

| ファイル | 変更内容 |
|----------|---------|
| `Sources/DatabaseManager.swift` | `init(inMemory:)` に `seedPresets: Bool = false` 引数を追加。`true` のとき `UserDefaults` チェックを飛ばして CSV を投入する内部メソッド `forceSeedPresets()` を呼ぶ |
| `Sources/Debug/DebugSocketServer.swift` | `handler = InputHandler(db: DatabaseManager(inMemory: true))` → `DatabaseManager(inMemory: true, seedPresets: true)` に変更 |

### 実装詳細

```swift
// DatabaseManager.swift

init(inMemory: Bool, seedPresets: Bool = false) {
    writeAsync = false
    guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return }
    createTables()
    ensureBigramIsPresetColumn()
    if seedPresets { forceSeedPresets() }
}

/// UserDefaults チェックなしで preset_bigram.csv を投入する（サンドボックス専用）
private func forceSeedPresets() {
    // seedPresetBigramsIfNeeded() の guard を除いた実装をそのまま使う
    // presetSeedUserDefaults への書き込みも不要
}
```

`seedPresetBigramsIfNeeded()` の本体（UserDefaults ガード行と最後の `.set` 行を除いたもの）を
`forceSeedPresets()` として `private` に切り出し、両者から呼ぶ形にリファクタリングする。

### テストへの影響

既存の `init(inMemory: true)` 呼び出しはデフォルト引数のまま `seedPresets: false` なので変更不要。

---

## 施策 2: 実 DB スナップショットモード

### 概要

`{"reset": true, "useRealDB": true}` コマンドで実際の `history.db` を一時ファイルにコピーして開く。
変換履歴・ユーザー辞書・boundary_pref・bigram 学習がすべてリアルな状態になる。
書き込みはコピー先のみに当たるため実データは汚染しない。

### 変更ファイル

| ファイル | 変更内容 |
|----------|---------|
| `Sources/DatabaseManager.swift` | `init(snapshotPath: String)` を追加。パスを受け取って `sqlite3_open` で開く（WAL 関連 PRAGMA は設定しない。read/write 両用）|
| `Sources/Debug/DebugSocketServer.swift` | `reset` コマンドに `useRealDB: Bool` を読み取るロジックを追加。`true` のとき DB をコピーして `snapshotPath` イニシャライザを使う。前回のスナップショットファイルを `deinit`/再 reset 時に削除する |

### 実装詳細

```swift
// DatabaseManager.swift

/// デバッグ用: 既存ファイル DB をそのまま開く（スナップショット等）
init(snapshotPath: String) {
    writeAsync = false
    guard sqlite3_open(snapshotPath, &db) == SQLITE_OK else { return }
    createTables()              // テーブルがなければ作る（通常は全部存在する）
    ensureBigramIsPresetColumn()
}
```

```swift
// DebugSocketServer.swift

private var snapshotURL: URL?   // 現セッションのスナップショット一時ファイル

private func processCommand(_ cmd: [String: Any]) -> [String: Any] {
    if cmd["reset"] != nil {
        cleanupSnapshot()       // 前回スナップショットを削除
        let useRealDB = cmd["useRealDB"] as? Bool ?? false
        if useRealDB, let db = makeRealDBSnapshot() {
            handler = InputHandler(db: db)
        } else {
            handler = InputHandler(db: DatabaseManager(inMemory: true, seedPresets: true))
        }
        // ... 既存の reset 処理
    }
}

private func makeRealDBSnapshot() -> DatabaseManager? {
    let src = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("keynaco/history.db")
    guard FileManager.default.fileExists(atPath: src.path) else { return nil }

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("keynaco-sandbox-\(UUID().uuidString).db")

    // WAL チェックポイントを実 DB に打ってからコピー（「WAL の扱い」セクション参照）
    // コピー失敗時は nil を返してインメモリにフォールバック
    guard checkpointAndCopy(src: src, dst: tmp) else { return nil }
    _ = tmp  // snapshotURL の設定は後

    snapshotURL = tmp
    return DatabaseManager(snapshotPath: tmp.path)
}

// 戻り値: コピー成功 true / 失敗 false
@discardableResult
private func checkpointAndCopy(src: URL, dst: URL) -> Bool {
    // 案 A: READWRITE で開いてチェックポイント（実装時に案 B と比較して選択）
    var tmpDb: OpaquePointer?
    if sqlite3_open_v2(src.path, &tmpDb, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
        sqlite3_busy_timeout(tmpDb, 500)
        sqlite3_exec(tmpDb, "PRAGMA wal_checkpoint(FULL);", nil, nil, nil)
        sqlite3_close(tmpDb)
    }
    do {
        try FileManager.default.copyItem(at: src, to: dst)
        return true
    } catch {
        NSLog("[DebugSocketServer] snapshot copy failed: \(error)")
        return false
    }
}

private func cleanupSnapshot() {
    if let url = snapshotURL {
        try? FileManager.default.removeItem(at: url)
        snapshotURL = nil
    }
}
```

### WAL の扱い

SQLite の `wal_checkpoint` は **書き込み権限を持つ接続が必要**（READONLY では実際には適用されない）。
実装では次の 2 案から選ぶ（実装時に動作確認して決定）。

**案 A（READWRITE + checkpoint + ファイルコピー）**
```swift
private func checkpointAndCopy(src: URL, dst: URL) {
    var tmpDb: OpaquePointer?
    // READWRITE で開いてチェックポイント（FULL = すべての WAL フレームをメインファイルに書き戻す）
    if sqlite3_open_v2(src.path, &tmpDb, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
        sqlite3_busy_timeout(tmpDb, 500)   // 最大 500ms 待つ
        sqlite3_exec(tmpDb, "PRAGMA wal_checkpoint(FULL);", nil, nil, nil)
        sqlite3_close(tmpDb)
    }
    // チェックポイント後はメインファイルだけコピーすれば一貫した状態になる
    try? FileManager.default.copyItem(at: src, to: dst)
}
```

**案 B（`sqlite3_backup` API）**  
チェックポイントを挟まず、バックアップ API がページ単位で一貫性を保ちながら dst に書き出す。
WAL の未コミット状態も吸収しやすいが、コード量が若干増える。

どちらの案でも：
- keynaco が DB をロック中で `SQLITE_BUSY` のとき、コピーが部分的に失敗する可能性がある  
  → `makeRealDBSnapshot()` は `copyItem` の結果を確認し、失敗なら `nil` を返してインメモリへフォールバック
- コピーが成功しても完全な瞬間一致は保証できないが、デバッグ用途として十分

### スキル（`keynaco-ime-sandbox`）の更新

`ARGUMENTS` セクションに以下を追記する:

```
# リセットオプション

| コマンド | 説明 |
|---------|------|
| `{"reset": true}` | インメモリ DB（preset bi-gram シード済み）でリセット |
| `{"reset": true, "useRealDB": true}` | 実 `history.db` スナップショットでリセット。変換履歴・ユーザー辞書・学習データがそのまま使える |

`history.db` が存在しない、またはコピー失敗（DB ロック等）の場合は `useRealDB` が無視され、
通常のインメモリ DB（preset bi-gram シード済み）でリセットされる。
スナップショットにはユーザーの変換履歴・語彙が含まれるため、ログ共有時は取り扱いに注意する。
```

---

## 実装順序

1. `DatabaseManager.swift`: `forceSeedPresets()` の切り出し → `init(inMemory:seedPresets:)` 対応
2. `DebugSocketServer.swift`: `seedPresets: true` に変更
3. ビルド＆動作確認（Successor モードで preset 候補が出ることを確認）
4. `DatabaseManager.swift`: `init(snapshotPath:)` 追加
5. `DebugSocketServer.swift`: `useRealDB` 分岐・`checkpointAndCopy`・`cleanupSnapshot` 実装
6. ビルド＆動作確認（`useRealDB: true` で実履歴の候補が出ることを確認）
7. スキルドキュメント更新

## 完了条件

- `{"reset": true}` でリセット後、`kyou` + Enter → Successor 候補に `は` / `も` 等の助詞が preset 由来で出る
- `{"reset": true, "useRealDB": true}` でリセット後、過去に実際に確定した単語が変換候補の上位に出る
