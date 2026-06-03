import Foundation
@testable import KeynacoCore

/// テストで使用する `AzooKeyConverting` の no-op ベース実装。
///
/// テスト用モックは個別に `AzooKeyConverting` を実装する代わりにこのクラスを継承し、
/// 必要なメソッドだけ `override` する。protocol に新メソッドが追加されても
/// このクラスだけ更新すれば既存モックはコンパイル可能なまま。
class BaseAzooKeyStub: AzooKeyConverting, @unchecked Sendable {
    var isZenzaiEnabled: Bool = false

    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = (hiragana, leftSideContext, richCandidates)
        return []
    }

    func requestConversionResult(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool
    ) -> AzooKeyConversionResult {
        let texts = requestCandidates(
            hiragana: hiragana,
            leftSideContext: leftSideContext,
            richCandidates: richCandidates
        )
        let len = max(1, hiragana.count)
        let rows = texts.map { AzooKeyClauseCandidate(text: $0, inputLength: len) }
        return AzooKeyConversionResult(mainResults: rows, firstClauseResults: [])
    }

    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        _ = (reading, leftSideContext)
        return []
    }

    func commit(reading: String, text: String) {
        _ = (reading, text)
    }

    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])] {
        _ = (hiragana, leftSideContext)
        return []
    }

    func lcidForCommitted(reading: String, output: String) -> Int? {
        _ = (reading, output)
        return nil
    }
}
