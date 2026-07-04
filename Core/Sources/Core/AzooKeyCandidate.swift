import Foundation

/// `AzooKeyConverter.requestCandidates` の表示候補。
public struct AzooKeyCandidate: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

extension AzooKeyCandidate {
    /// テスト・スタブ用。
    public static func text(_ text: String) -> AzooKeyCandidate {
        AzooKeyCandidate(text: text)
    }
}

extension Array where Element == AzooKeyCandidate {
    public var texts: [String] { map(\.text) }
}
