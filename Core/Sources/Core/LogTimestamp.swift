import Foundation

/// JSONL ログ向けの ISO8601 タイムスタンプ整形。
///
/// `ts` は性質ごとに ms / 秒で記録単位が違う（latency_log は秒、input_log・divergence_log は ms）。
/// 機械処理向けの数値はそのまま、人間が読むときに単位を読み違える事故を防ぐため
/// 各エントリに `ts_iso`（例: `2026-06-20T10:25:30.187Z`）を併記する。
public enum LogTimestamp {
    public static func iso8601(fromUnixMs ms: Int) -> String {
        iso8601String(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    public static func iso8601(fromUnixSec sec: Int) -> String {
        iso8601String(from: Date(timeIntervalSince1970: Double(sec)))
    }

    public static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
