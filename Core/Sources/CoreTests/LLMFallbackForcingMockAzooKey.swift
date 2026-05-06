import Foundation
@testable import KeynacoCore

/// `candidatesForSegment` を常に空にし `inferSegmentBoundaries` を失敗させる。`segmentize` だけ
/// `わたしはがくせい` 用の文節分割を返し、先頭文節への LLM 全文挿入フォールバックのテストを辞書非依存にする。
final class LLMFallbackForcingMockAzoo: AzooKeyConverting, @unchecked Sendable {
    /// Zenzai off のフォールバック挿入を検証するため明示（本変更の Zenzai on 早期 return ではこの分岐に入らない）。
    var isZenzaiEnabled: Bool { false }
    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = (hiragana, leftSideContext, richCandidates)
        return []
    }
    func commit(reading: String, text: String) {}
    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        _ = (reading, leftSideContext)
        return []
    }
    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])] {
        _ = leftSideContext
        guard hiragana == "わたしはがくせい" else { return [] }
        return [
            ("わたし", []),
            ("は", []),
            ("がくせい", [])
        ]
    }
}
