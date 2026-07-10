import Foundation

/// AzooKey 候補 `data` の 1 セグメント（PLAN260710a POC / D1 用）。
public struct AzooKeySegmentSnapshot: Equatable, Sendable {
    public let word: String
    public let ruby: String
    public let lcid: Int
    public let rcid: Int
    public let isJoshiLcid: Bool
    public let isJoshiRcid: Bool

    public init(
        word: String,
        ruby: String,
        lcid: Int,
        rcid: Int,
        isJoshiLcid: Bool,
        isJoshiRcid: Bool
    ) {
        self.word = word
        self.ruby = ruby
        self.lcid = lcid
        self.rcid = rcid
        self.isJoshiLcid = isJoshiLcid
        self.isJoshiRcid = isJoshiRcid
    }

    public var description: String {
        "\(word)/\(ruby) lcid=\(lcid)\(isJoshiLcid ? "(joshi)" : "") rcid=\(rcid)\(isJoshiRcid ? "(joshi)" : "")"
    }
}
