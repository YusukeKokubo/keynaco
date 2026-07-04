import Foundation

/// `requestCandidates` のオプション（whileTyping 用 Zenzai 段階化・stale fetch 中断）。
public struct AzooKeyFetchOptions: @unchecked Sendable {
    /// `nil` = converter の既定 `zenzaiInferenceLimit`（通常 5）。
    public var zenzaiInferenceLimit: Int?
    /// `withLock` 突入直後に `true` なら変換せず `[]` を返す（世代不一致の stale fetch 用）。
    public var abortBeforeFetch: (@Sendable () -> Bool)?

    public init(
        zenzaiInferenceLimit: Int? = nil,
        abortBeforeFetch: (@Sendable () -> Bool)? = nil
    ) {
        self.zenzaiInferenceLimit = zenzaiInferenceLimit
        self.abortBeforeFetch = abortBeforeFetch
    }

    public static let `default` = AzooKeyFetchOptions()
}
