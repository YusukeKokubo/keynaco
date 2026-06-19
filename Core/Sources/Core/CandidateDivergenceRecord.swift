import Foundation

/// Zenzai が推した Z1 と、ユーザーの実確定が食い違ったときの 1 件の記録。
///
/// `was_explicit=false` のエントリは「自動表示中の Space で素通り確定された」サイレント事故、
/// `was_explicit=true` のエントリは「ユーザーが明示的に Z2 以下を選んだ」Zenzai 精度の改善余地。
/// 両方とも `divergence_log.jsonl` で後追い分析できる。
public struct CandidateDivergenceRecord: Sendable, Equatable {
    public let ts: Int
    public let reading: String
    /// Zenzai/AzooKey 順序の先頭。
    public let z1: String
    public let confirmed: String
    public let selectedRow: Int
    public let wasExplicit: Bool
    public let candidates: [String]
    public let leftContext: String?

    public init(
        ts: Int,
        reading: String,
        z1: String,
        confirmed: String,
        selectedRow: Int,
        wasExplicit: Bool,
        candidates: [String],
        leftContext: String?
    ) {
        self.ts = ts
        self.reading = reading
        self.z1 = z1
        self.confirmed = confirmed
        self.selectedRow = selectedRow
        self.wasExplicit = wasExplicit
        self.candidates = candidates
        self.leftContext = leftContext
    }

    public func asDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "ts": ts,
            "reading": reading,
            "z1": z1,
            "confirmed": confirmed,
            "selected_row": selectedRow,
            "was_explicit": wasExplicit,
            "candidates": candidates,
        ]
        if let leftContext { dict["left_context"] = leftContext }
        return dict
    }
}
