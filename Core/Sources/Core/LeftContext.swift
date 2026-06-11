import Foundation

public struct IMKSurroundingSnapshot: Equatable, Sendable {
    public var location: Int
    public var before: String
    public var after: String

    public init(location: Int, before: String, after: String) {
        self.location = location
        self.before = before
        self.after = after
    }
}

public struct LeftContextIMKCache: Equatable, Sendable {
    public var snapshot: IMKSurroundingSnapshot?
    public var invalidated: Bool = false

    public init(snapshot: IMKSurroundingSnapshot? = nil, invalidated: Bool = false) {
        self.snapshot = snapshot
        self.invalidated = invalidated
    }
}

/// 左文脈の解決結果。`sessionBuffer` / `imkBefore` / `combined` を1対1で保持する。
public struct LeftContext: Equatable, Sendable {
    public var sessionBuffer: String
    /// 解決時に採用された effective IMK `before`
    public var imkBefore: String?
    /// 300/400 字結合後（AzooKey / Zenzai API 引数の実体）
    public var combined: String

    public var azooKeyValue: String? { combined.isEmpty ? nil : combined }

    public static let empty = LeftContext(sessionBuffer: "", imkBefore: nil, combined: "")

    public init(sessionBuffer: String, imkBefore: String?, combined: String) {
        self.sessionBuffer = sessionBuffer
        self.imkBefore = imkBefore
        self.combined = combined
    }

    /// テスト用: 結合結果のみ指定する。
    public static func testing(combined: String) -> Self {
        .init(sessionBuffer: "", imkBefore: nil, combined: combined)
    }
}
