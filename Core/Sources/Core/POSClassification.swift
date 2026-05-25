import Foundation

/// 品詞分類結果。
public struct POSClassification: Sendable, Equatable {
    public let pos: String

    public init(pos: String) {
        self.pos = pos
    }
}
