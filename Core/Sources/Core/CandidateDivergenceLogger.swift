import Foundation

/// 候補分岐ログ（`divergence_log.jsonl`）への書き込み。`InputQualityLogger` と同パターン。
public final class CandidateDivergenceLogger {
    private static let logLabel = "divergence log"
    private let buffer: BufferedJSONLLogger

    public init(fileURL: URL = CandidateDivergenceLogger.logURL) {
        buffer = BufferedJSONLLogger(threshold: 10, fileURL: fileURL, logLabel: Self.logLabel)
    }

    public static var logURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("keynaco", isDirectory: true)
            .appendingPathComponent("divergence_log.jsonl")
    }

    public func append(record: CandidateDivergenceRecord, appVersion: String) {
        var dict = record.asDictionary()
        dict["version"] = appVersion
        dict["ts_iso"] = LogTimestamp.iso8601(fromUnixMs: record.ts)
        buffer.append(dict)
    }

    public func flushForced() {
        buffer.flushForced()
    }

    /// 起動時に古い行を切り詰める。30 日分 or 最新 20000 件（先に超えた方）。7 日に 1 回だけ実行。
    public static func trimIfNeeded(fileURL: URL) {
        JSONLWriter.trimIfNeeded(fileURL: fileURL, policy: .divergenceLog)
    }
}
