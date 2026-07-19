import Foundation

/// `requestCandidates` のオプション（whileTyping 用 Zenzai 段階化）。
public struct AzooKeyFetchOptions: Sendable {
    /// `nil` = converter の既定 `zenzaiInferenceLimit`（通常 5）。
    public var zenzaiInferenceLimit: Int?

    public init(zenzaiInferenceLimit: Int? = nil) {
        self.zenzaiInferenceLimit = zenzaiInferenceLimit
    }

    public static let `default` = AzooKeyFetchOptions()
}
