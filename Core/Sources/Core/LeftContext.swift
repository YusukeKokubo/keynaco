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

public enum LeftContextIMKCache: Equatable, Sendable {
    case empty
    case valid(IMKSurroundingSnapshot)
    /// キー処理中に無効化された。`applyPostKeyDown` で `.empty` に遷移する。
    case invalidated

    public init() { self = .empty }

    /// キャッシュ済みスナップショット。`.valid` 以外は nil。
    public var snapshot: IMKSurroundingSnapshot? {
        guard case .valid(let snap) = self else { return nil }
        return snap
    }

    public var isInvalidated: Bool { self == .invalidated }
}

/// 左文脈の解決結果。`sessionBuffer` / `imkBefore` / `combined` を1対1で保持する。
public struct LeftContext: Equatable, Sendable {
    public var sessionBuffer: String
    /// 解決時に採用された effective IMK `before`
    public var imkBefore: String?
    /// 300/400 字結合後（AzooKey / Zenzai API 引数の実体）
    public var combined: String

    /// AzooKey / Zenzai API に渡す左文脈。`combined` が空（カーソル位置未取得・文脈なし）のときは
    /// nil を渡して「文脈なし」扱いにする（空文字列と nil は API 的に等価だが nil の方が意図明確）。
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
