import Foundation

/// AzooKey `requestCandidates` の 1 候補（表層 + 消費する読み長）。
public struct AzooKeyClauseCandidate: Sendable, Equatable {
    public let text: String
    public let inputLength: Int

    public init(text: String, inputLength: Int) {
        self.text = text
        self.inputLength = max(1, inputLength)
    }
}

/// `ConversionResult` の Desktop 利用分（`mainResults` / `firstClauseResults`）。
public struct AzooKeyConversionResult: Sendable, Equatable {
    public let mainResults: [AzooKeyClauseCandidate]
    public let firstClauseResults: [AzooKeyClauseCandidate]

    public init(
        mainResults: [AzooKeyClauseCandidate],
        firstClauseResults: [AzooKeyClauseCandidate]
    ) {
        self.mainResults = mainResults
        self.firstClauseResults = firstClauseResults
    }
}

/// azooKey-Desktop `SegmentsManager.rawCandidatesList` と同じマージ規則。
public enum AzooKeyCandidateMerge {
    /// 文節境界を手動編集したあとは `mainResults` のみ。
    public static func mergedList(
        result: AzooKeyConversionResult,
        convertTarget: String,
        segmentEdition: Bool
    ) -> [AzooKeyClauseCandidate] {
        if segmentEdition {
            return result.mainResults
        }
        if result.firstClauseResults.contains(where: { $0.inputLength >= convertTarget.count }) {
            return result.mainResults
        }
        let seen = Set(result.firstClauseResults.map(\.text))
        return result.firstClauseResults + result.mainResults.filter { !seen.contains($0.text) }
    }
}
