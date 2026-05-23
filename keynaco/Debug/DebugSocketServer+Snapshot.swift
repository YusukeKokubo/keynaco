#if DEBUG

import Foundation
import KeynacoCore
import SQLite3

extension DebugSocketServer {
    // MARK: - 実 DB スナップショット（デバッグ用）

    func cleanupSnapshot() {
        Self.removeSnapshotArtifacts(baseURL: snapshotURL)
        snapshotURL = nil
    }

    /// `foo.db` と SQLite が隣接生成する `foo.db-wal` / `foo.db-shm` をまとめて削除する。
    nonisolated static func removeSnapshotArtifacts(baseURL: URL?) {
        guard let base = baseURL else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: base)
        try? fm.removeItem(at: URL(fileURLWithPath: base.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: base.path + "-shm"))
    }

    func makeRealDBSnapshot() -> DatabaseManager? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let src = appSupport.appendingPathComponent("keynaco", isDirectory: true).appendingPathComponent("history.db")
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keynaco-sandbox-\(UUID().uuidString).db")

        guard copyDatabaseToSnapshot(src: src, dst: tmp) else { return nil }

        snapshotURL = tmp
        return DatabaseManager(snapshotPath: tmp.path)
    }

    /// まず `sqlite3_backup`、失敗時はチェックポイント + 本体ファイルコピー（後者は WAL がマージできない場合にデータ欠落しうる）。
    func copyDatabaseToSnapshot(src: URL, dst: URL) -> Bool {
        try? FileManager.default.removeItem(at: dst)
        Self.removeSnapshotArtifacts(baseURL: dst)

        if copyDatabaseUsingBackup(src: src, dst: dst) {
            return true
        }
        NSLog("[DebugSocketServer] sqlite3_backup failed; falling back to checkpoint + file copy (see checkpointAndCopyDbOnly comment)")
        try? FileManager.default.removeItem(at: dst)
        Self.removeSnapshotArtifacts(baseURL: dst)
        return checkpointAndCopyDbOnly(src: src, dst: dst)
    }

    func copyDatabaseUsingBackup(src: URL, dst: URL) -> Bool {
        var destDb: OpaquePointer?
        guard sqlite3_open_v2(dst.path, &destDb, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let dest = destDb else { return false }
        defer { sqlite3_close(dest) }

        // バックアップ元はリーダーロックで足りる。READWRITE だと本番が WAL で掴んでいるとき BUSY になりやすい。
        var srcDb: OpaquePointer?
        guard sqlite3_open_v2(src.path, &srcDb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let source = srcDb else { return false }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 500)

        guard let backup = sqlite3_backup_init(dest, "main", source, "main") else { return false }
        defer { _ = sqlite3_backup_finish(backup) }

        while true {
            let rc = sqlite3_backup_step(backup, -1)
            if rc == SQLITE_DONE { return true }
            if rc == SQLITE_OK { continue }
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                usleep(20_000)
                continue
            }
            return false
        }
    }

    /// 案 A: メインファイルのみコピー。`PRAGMA wal_checkpoint(FULL)` が効かないと `-wal` 内の未反映フレームはコピー先に乗らない（デバッグ用途では許容）。
    func checkpointAndCopyDbOnly(src: URL, dst: URL) -> Bool {
        try? FileManager.default.removeItem(at: dst)
        Self.removeSnapshotArtifacts(baseURL: dst)
        var tmpDb: OpaquePointer?
        if sqlite3_open_v2(src.path, &tmpDb, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = tmpDb {
            sqlite3_busy_timeout(db, 500)
            sqlite3_exec(db, "PRAGMA wal_checkpoint(FULL);", nil, nil, nil)
            sqlite3_close(db)
        }
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            return true
        } catch {
            NSLog("[DebugSocketServer] snapshot copy failed: \(error)")
            return false
        }
    }
}

#endif
