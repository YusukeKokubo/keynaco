import Foundation
@testable import KeynacoCore

/// テストで使用する `AzooKeyConverting` の no-op ベース実装。
///
/// テスト用モックは個別に `AzooKeyConverting` を実装する代わりにこのクラスを継承し、
/// 必要なメソッドだけ `override` する。protocol に新メソッドが追加されても
/// このクラスだけ更新すれば既存モックはコンパイル可能なまま。
class BaseAzooKeyStub: AzooKeyConverting, @unchecked Sendable {
    var isZenzaiEnabled: Bool = false
    let latencyStats = TypingLatencyStats()

    func requestCandidates(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool,
        options: AzooKeyFetchOptions
    ) -> [AzooKeyCandidate] {
        _ = (hiragana, leftSideContext, richCandidates, options)
        return []
    }

    func peekCachedCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> AzooKeyCachePeek? {
        _ = (hiragana, leftSideContext, richCandidates)
        return nil
    }

    func commit(reading: String, text: String) {
        _ = (reading, text)
    }

    func lcidForCommitted(reading: String, output: String) -> Int? {
        _ = (reading, output)
        return nil
    }
}
