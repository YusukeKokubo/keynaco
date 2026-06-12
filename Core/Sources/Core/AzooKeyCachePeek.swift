import Foundation

/// `AzooKeyConverter.candidateCache` の同期参照結果（非同期取得を待たず即時候補に使う）。
public struct AzooKeyCachePeek: Equatable, Sendable {
    public enum Match: Equatable, Sendable {
        case exact
        /// より短い読みのキャッシュを暫定表示に流用（例: `かん` の結果を `かんじ` 待ち中に表示）。
        case prefix(sourceReading: String)
    }

    public let candidates: [String]
    public let match: Match

    public init(candidates: [String], match: Match) {
        self.candidates = candidates
        self.match = match
    }

    /// `false` のとき非同期 AzooKey 取得は不要（完全一致キャッシュヒット）。
    public var needsAsyncFetch: Bool {
        switch match {
        case .exact: return false
        case .prefix: return true
        }
    }
}
