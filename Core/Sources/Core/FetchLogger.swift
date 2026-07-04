import Foundation

/// `fetch_log.jsonl` — `AzooKeyConverter.requestCandidates` の実行ごとに 1 行記録する詳細ログ。
///
/// 集計値（`latency_log` の p50/p95）では「どの読みで lock 詰まったか」「どの fetch が wasted だったか」が
/// 見えない。fetch 単位で reading・lock 待ち時間・fetch 所要時間を残し、debounce 改修の効果を
/// reading-level で追えるようにする。
///
/// プライバシー: `reading` フィールドはユーザーの入力（途中状態含む）をそのまま記録する。
/// `~/Library/Application Support/keynaco/` 配下のみ。
public final class FetchLogger: @unchecked Sendable {
    private static let logLabel = "fetch log"

    /// `AzooKeyConverting` の default 実装で使う共有 no-op インスタンス。
    /// stub から `appVersion` セット等を呼んでもどこにも書かれず、ディスクへの副作用なし。
    public static let sharedNoOp = FetchLogger()

    private let lock = NSLock()
    private var appVersionStorage = "0.0.0"
    private let buffer: BufferedJSONLLogger

    public init(outputURL: URL = FetchLogger.logURL) {
        buffer = BufferedJSONLLogger(threshold: 50, fileURL: outputURL, logLabel: Self.logLabel)
    }

    public var appVersion: String {
        get { lock.withLock { appVersionStorage } }
        set { lock.withLock { appVersionStorage = newValue } }
    }

    public static var logURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("keynaco", isDirectory: true)
            .appendingPathComponent("fetch_log.jsonl")
    }

    public func append(
        reading: String,
        leftContext: String?,
        fetchMs: Double,
        lockWaitMs: Double,
        rich: Bool,
        zenzaiEnabled: Bool
    ) {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        var dict: [String: Any] = [
            "ts": nowMs,
            "ts_iso": LogTimestamp.iso8601(fromUnixMs: nowMs),
            "reading": reading,
            "reading_len": reading.count,
            "fetch_ms": Int(fetchMs.rounded()),
            "lock_wait_ms": Int(lockWaitMs.rounded()),
            "rich": rich,
            "zenzai": zenzaiEnabled,
            "wasted": false,
        ]
        lock.withLock {
            dict["version"] = appVersionStorage
            if let leftContext, !leftContext.isEmpty {
                dict["left_context"] = leftContext
            }
        }
        buffer.append(dict)
    }

    /// debounce 中に世代が進み fetch 結果が破棄された行を `wasted: true` に更新する。
    /// 直近の未フラッシュ行を後方から `reading` で探す（通常は fetch 直後に呼ばれる）。
    public func markLastFetchWasted(matchingReading reading: String) {
        buffer.withBufferLock { buffer in
            for index in buffer.indices.reversed() {
                guard buffer[index]["reading"] as? String == reading else { continue }
                buffer[index]["wasted"] = true
                return
            }
        }
    }

    public func flushForced() {
        buffer.flushForced()
    }

    /// 起動時に古い行を切り詰める。30 日分 or 最新 100000 行（先に超えた方）。7 日に 1 回だけ実行。
    /// fetch は 1 セッション数百件出るため `input_log`（20000 行）より大きな上限。
    public static func trimIfNeeded(fileURL: URL = FetchLogger.logURL) {
        JSONLWriter.trimIfNeeded(fileURL: fileURL, policy: .fetchLog)
    }
}
