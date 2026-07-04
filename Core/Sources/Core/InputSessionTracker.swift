import Foundation

/// 1変換セッション（組成開始〜確定/キャンセル）の打鍵データを蓄積する純粋 struct。副作用なし。
public struct InputSessionTracker {
    public private(set) var keyCount = 0
    public private(set) var bsCount = 0
    public private(set) var scrollCount = 0
    /// 候補 explicit 選択中に押された BS の回数。
    /// 旧挙動では explicit を維持したまま rebuild されて marked text がちらついていた
    /// （`InputHandlerBackspaceTests.testBackspaceDemotesExplicitSelectionToPassive` 参照）。
    public private(set) var bsExplicitCount = 0
    /// 2 char → 1 char に縮めた BS の回数。
    /// 旧挙動では `state.backspace().needsRefresh = false` で候補窓が dismiss されていた。
    public private(set) var bsShrunkToOneCount = 0
    /// このセッションで観測した最大の候補 selectedRow。
    /// 確定時の selectedRow がこの値より小さければ「巻き戻り」が起きている（async fetch の `.show` で row=0 に戻された等）。
    public private(set) var maxObservedSelectedRow = 0
    private var startedAtMs: Int?

    public mutating func track(keyCode: UInt16) {
        if startedAtMs == nil {
            startedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        }
        keyCount += 1
        if keyCode == KeyCode.backspace { bsCount += 1 }
        if keyCode == KeyCode.downArrow || keyCode == KeyCode.upArrow { scrollCount += 1 }
    }

    /// `doBackspace` から呼ぶ。`wasExplicit` は BS 実行前の候補状態、`composedAfter` は state.backspace() 後の char 数。
    public mutating func trackBackspaceContext(wasExplicit: Bool, composedAfter: Int) {
        if wasExplicit { bsExplicitCount += 1 }
        if composedAfter == 1 { bsShrunkToOneCount += 1 }
    }

    /// `applyCandidateAction` 直後の `candidateSession.selectedRow` を引数に呼ぶ。最大値だけを保持する。
    public mutating func trackSelectedRow(_ row: Int) {
        if row > maxObservedSelectedRow { maxObservedSelectedRow = row }
    }

    public mutating func reset() {
        self = InputSessionTracker()
    }

    func compositionMs(endMs: Int) -> Int {
        guard let start = startedAtMs else { return 0 }
        return endMs - start
    }

    /// `commitComposition` / `doEscape` 共通の `InputSessionRecord` 組み立て。
    func makeSessionRecord(
        ts: Int,
        reading: String,
        committed: String?,
        candidateDepth: Int?,
        wasExplicit: Bool,
        anomaly: [String]
    ) -> InputSessionRecord {
        InputSessionRecord(
            ts: ts,
            keyCount: keyCount,
            bsCount: bsCount,
            compositionMs: compositionMs(endMs: ts),
            reading: reading,
            committed: committed,
            candidateDepth: candidateDepth,
            wasExplicit: wasExplicit,
            scrollCount: scrollCount,
            anomaly: anomaly,
            bsExplicitCount: bsExplicitCount,
            bsShrunkToOneCount: bsShrunkToOneCount,
            maxObservedSelectedRow: maxObservedSelectedRow
        )
    }
}

/// 1変換セッションのログエントリ。`InputQualityLogger` が JSONL に書き出す。
public struct InputSessionRecord: Sendable {
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
    public let bsExplicitCount: Int
    public let bsShrunkToOneCount: Int
    public let maxObservedSelectedRow: Int

    public init(
        ts: Int, keyCount: Int, bsCount: Int, compositionMs: Int,
        reading: String, committed: String?, candidateDepth: Int?,
        wasExplicit: Bool, scrollCount: Int, anomaly: [String],
        bsExplicitCount: Int = 0, bsShrunkToOneCount: Int = 0,
        maxObservedSelectedRow: Int = 0
    ) {
        self.ts = ts
        self.keyCount = keyCount
        self.bsCount = bsCount
        self.compositionMs = compositionMs
        self.reading = reading
        self.committed = committed
        self.candidateDepth = candidateDepth
        self.wasExplicit = wasExplicit
        self.scrollCount = scrollCount
        self.anomaly = anomaly
        self.bsExplicitCount = bsExplicitCount
        self.bsShrunkToOneCount = bsShrunkToOneCount
        self.maxObservedSelectedRow = maxObservedSelectedRow
    }

    public func addingAnomaly(_ kind: String) -> InputSessionRecord {
        InputSessionRecord(
            ts: ts, keyCount: keyCount, bsCount: bsCount,
            compositionMs: compositionMs, reading: reading, committed: committed,
            candidateDepth: candidateDepth, wasExplicit: wasExplicit,
            scrollCount: scrollCount, anomaly: anomaly + [kind],
            bsExplicitCount: bsExplicitCount, bsShrunkToOneCount: bsShrunkToOneCount,
            maxObservedSelectedRow: maxObservedSelectedRow
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
        if bsExplicitCount > 0 {
            dict["bs_explicit_count"] = bsExplicitCount
        }
        if bsShrunkToOneCount > 0 {
            dict["bs_shrunk_to_one"] = bsShrunkToOneCount
        }
        if maxObservedSelectedRow > 0 {
            dict["max_observed_row"] = maxObservedSelectedRow
        }
        return dict
    }
}
