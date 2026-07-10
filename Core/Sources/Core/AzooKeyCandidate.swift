import Foundation

/// `AzooKeyConverter.requestCandidates` の表示候補。
public struct AzooKeyCandidate: Equatable, Sendable {
    public let text: String
    /// PLAN260710a: `data.count >= 2` かつ末尾セグメント lcid が joshi のとき true。
    /// 確定時の履歴助詞トリムに使う。履歴・ユーザー辞書等では常に false。
    public let shouldTrimTrailingJoshi: Bool

    public init(text: String, shouldTrimTrailingJoshi: Bool = false) {
        self.text = text
        self.shouldTrimTrailingJoshi = shouldTrimTrailingJoshi
    }
}

extension AzooKeyCandidate {
    /// テスト・スタブ用。
    public static func text(_ text: String, shouldTrimTrailingJoshi: Bool = false) -> AzooKeyCandidate {
        AzooKeyCandidate(text: text, shouldTrimTrailingJoshi: shouldTrimTrailingJoshi)
    }
}

extension Array where Element == AzooKeyCandidate {
    public var texts: [String] { map(\.text) }
}
