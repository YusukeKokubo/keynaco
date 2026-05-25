import Foundation
import KeynacoCore

enum SyncSettings {
    private static let nasPathKey = "syncNASPath"
    private static let syncOnQuitKey = "syncOnQuit"

    static var nasPath: String? {
        get { UserDefaults.standard.string(forKey: nasPathKey) }
        set { UserDefaults.standard.set(newValue, forKey: nasPathKey) }
    }

    static var syncOnQuit: Bool {
        get { UserDefaults.standard.bool(forKey: syncOnQuitKey) }
        set { UserDefaults.standard.set(newValue, forKey: syncOnQuitKey) }
    }

    /// DB を NAS へ書き出す。completionHandler は任意のスレッドから呼ばれる。
    static func exportToNAS(completion: @escaping @Sendable (Bool, String) -> Void) {
        guard let nasPath = nasPath, !nasPath.isEmpty else {
            completion(false, "NAS パスが未設定です")
            return
        }
        let dir = URL(fileURLWithPath: nasPath).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        DatabaseManager.shared.checkpoint()
        run(args: ["-av", "--checksum", DatabaseManager.dbPath, nasPath], completion: completion)
    }

    /// NAS から DB を取り込む。completionHandler は任意のスレッドから呼ばれる。
    static func importFromNAS(completion: @escaping @Sendable (Bool, String) -> Void) {
        guard let nasPath = nasPath, !nasPath.isEmpty else {
            completion(false, "NAS パスが未設定です")
            return
        }
        run(args: ["-av", "--checksum", nasPath, DatabaseManager.dbPath]) { ok, output in
            if ok { DatabaseManager.shared.reopen() }
            completion(ok, output)
        }
    }

    private static func run(args: [String], completion: @escaping @Sendable (Bool, String) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.terminationHandler = { process in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            completion(process.terminationStatus == 0, out)
        }
        do {
            try task.run()
        } catch {
            completion(false, error.localizedDescription)
        }
    }
}
