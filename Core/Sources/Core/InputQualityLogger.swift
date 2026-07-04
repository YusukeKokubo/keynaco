import Foundation

/// 入力品質ログ（`input_log.jsonl`）への書き込みとトリミングを担う。
///
/// メインスレッドから呼ぶ前提。`buffer` に 10 件蓄積してからまとめて書き込むことで
/// セッション確定ごとの同期 I/O を避ける。アプリ非アクティブ時は `flushForced()` で強制書き出し。
public final class InputQualityLogger {
    private static let logLabel = "input log"
    private let buffer: BufferedJSONLLogger

    public init(fileURL: URL = InputQualityLogger.inputLogURL) {
        buffer = BufferedJSONLLogger(threshold: 10, fileURL: fileURL, logLabel: Self.logLabel)
    }

    public static var inputLogURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("keynaco", isDirectory: true)
            .appendingPathComponent("input_log.jsonl")
    }

    public func append(record: InputSessionRecord, appVersion: String) {
        var dict = record.asDictionary()
        dict["version"] = appVersion
        dict["ts_iso"] = LogTimestamp.iso8601(fromUnixMs: record.ts)
        buffer.append(dict)
    }

    /// バッファ内容を即座に書き出す。アプリ非アクティブ時（`deactivateServer`）に呼ぶ。
    public func flushForced() {
        buffer.flushForced()
    }

    /// 起動時に古い行を切り詰める。30 日分 or 最新 20000 セッション（先に超えた方）。7 日に 1 回だけ実行。
    public static func trimIfNeeded(fileURL: URL) {
        JSONLWriter.trimIfNeeded(fileURL: fileURL, policy: .inputLog)
    }
}
