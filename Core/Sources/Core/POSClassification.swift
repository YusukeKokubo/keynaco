import Foundation

/// LLM / DB キャッシュから得る品詞分類結果。
public struct POSClassification: Sendable, Equatable {
    public let pos: String
    public let posTag: String
    public let posRetry: Bool
    public let lemma: String?

    public init(pos: String, posTag: String, posRetry: Bool, lemma: String? = nil) {
        self.pos = pos
        self.posTag = posTag
        self.posRetry = posRetry
        self.lemma = lemma
    }
}
