import Foundation

/// 品詞分類結果。辞書ルックアップ時は `lcid` に AzooKey 接続 ID を保持する。
public struct POSClassification: Sendable, Equatable {
    public let pos: String?
    public let lcid: Int?

    public init(pos: String, lcid: Int? = nil) {
        self.pos = pos
        self.lcid = lcid
    }

    /// 辞書から `lcid` のみ取得でき、`pos` への写像はできなかった場合。
    init(lcid: Int) {
        self.pos = nil
        self.lcid = lcid
    }
}
