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
    /// 確定候補のセクション由来。"fixed"（ひらがな固定/ユーザー辞書）/ "history" / "dict"。
    public let confirmedSource: String
    /// `.show` 時の初期選択行。ユーザーがスクロールしていれば `selectedRow` と異なる。
    public let initialRow: Int
    /// 初期行を選んだ理由。"promotedPrefixHistory" / "exactMatchHistory" / "userDictExact" / "prefixFocus" / "azooKey" / "afterFixed"。
    public let initialRowReason: String

    /// Z1 と確定がズレた要因。
    ///
    /// - `nil`（= `was_explicit=true`）: ユーザーが手で候補を navigate して選んだ。**真の UX 損失**で、
    ///   Zenzai 精度の改善余地を示す（例: row 4 以下まで掘って選んだ）。
    /// - 非 nil（= `was_explicit=false`）: 自動表示中に Z1 以外が初期行になり、ユーザーは何もしなくても正解に当たった。
    ///   値は `confirmedSource`（"history" / "dict" / "fixed" / "userDict"）と一致。
    ///   **UX 損失ではなく、履歴・辞書が Zenzai の粗さをカバーした証拠**として読む。
    public var rescuedBy: String? {
        if wasExplicit { return nil }
        return confirmedSource.isEmpty ? nil : confirmedSource
    }

    public init(
        ts: Int,
        reading: String,
        z1: String,
        confirmed: String,
        selectedRow: Int,
        wasExplicit: Bool,
        candidates: [String],
        leftContext: String?,
        confirmedSource: String,
        initialRow: Int,
        initialRowReason: String
    ) {
        self.ts = ts
        self.reading = reading
        self.z1 = z1
        self.confirmed = confirmed
        self.selectedRow = selectedRow
        self.wasExplicit = wasExplicit
        self.candidates = candidates
        self.leftContext = leftContext
        self.confirmedSource = confirmedSource
        self.initialRow = initialRow
        self.initialRowReason = initialRowReason
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
            "confirmed_source": confirmedSource,
            "initial_row": initialRow,
            "initial_row_reason": initialRowReason,
        ]
        if let leftContext { dict["left_context"] = leftContext }
        if let rescued = rescuedBy { dict["rescued_by"] = rescued }
        return dict
    }
}
