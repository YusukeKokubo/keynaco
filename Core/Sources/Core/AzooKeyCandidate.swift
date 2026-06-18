import Foundation

/// `AzooKeyConverter.requestCandidates` の表示候補。`Candidate.data` のセグメント数を型に出す。
public struct AzooKeyCandidate: Equatable, Sendable {
    public let text: String
    /// `Candidate.data.count`（形態素セグメント数）。
    public let segmentCount: Int

    public init(text: String, segmentCount: Int) {
        self.text = text
        self.segmentCount = segmentCount
    }
}

extension AzooKeyCandidate {
    /// テスト・スタブ用。セグメント数 1 として構築する。
    public static func text(_ text: String) -> AzooKeyCandidate {
        AzooKeyCandidate(text: text, segmentCount: 1)
    }
}

extension Array where Element == AzooKeyCandidate {
    public var texts: [String] { map(\.text) }
}
