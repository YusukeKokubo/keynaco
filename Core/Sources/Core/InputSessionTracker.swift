import Foundation

/// 1変換セッション（組成開始〜確定/キャンセル）の打鍵データを蓄積する純粋 struct。副作用なし。
public struct InputSessionTracker {
    public private(set) var keyCount = 0
    public private(set) var bsCount = 0
    public private(set) var scrollCount = 0
    private var startedAtMs: Int?

    public mutating func track(keyCode: UInt16) {
        if startedAtMs == nil {
            startedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        }
        keyCount += 1
        if keyCode == KeyCode.backspace { bsCount += 1 }
        if keyCode == KeyCode.downArrow || keyCode == KeyCode.upArrow { scrollCount += 1 }
    }

    public mutating func reset() {
        self = InputSessionTracker()
    }

    func compositionMs(endMs: Int) -> Int {
        guard let start = startedAtMs else { return 0 }
        return endMs - start
    }
}

/// 1変換セッションのログエントリ。`InputQualityLogger` が JSONL に書き出す。
public struct InputSessionRecord {
    public let ts: Int
    public let keyCount: Int
    public let bsCount: Int
    public let compositionMs: Int
    public let reading: String
    public let committed: String?
    public let candidateDepth: Int?
    public let wasExplicit: Bool
    public let scrollCount: Int
    public let anomaly: [String]

    public func addingAnomaly(_ kind: String) -> InputSessionRecord {
        InputSessionRecord(
            ts: ts, keyCount: keyCount, bsCount: bsCount,
            compositionMs: compositionMs, reading: reading, committed: committed,
            candidateDepth: candidateDepth, wasExplicit: wasExplicit,
            scrollCount: scrollCount, anomaly: anomaly + [kind]
        )
    }

    public func asDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "ts": ts,
            "key_count": keyCount,
            "bs_count": bsCount,
            "composition_ms": compositionMs,
            "reading": reading,
            "was_explicit": wasExplicit,
            "scroll_count": scrollCount,
        ]
        if let committed {
            dict["committed"] = committed
        } else {
            dict["committed"] = NSNull()
        }
        if let depth = candidateDepth {
            dict["candidate_depth"] = depth
        }
        if !anomaly.isEmpty {
            dict["anomaly"] = anomaly
        }
        return dict
    }
}
