import Foundation
@testable import KeynacoCore

/// `candidatesForSegment` を常に空にし `inferSegmentBoundaries` を失敗させる。`segmentize` だけ
/// `わたしはがくせい` 用の文節分割を返し、先頭文節への LLM 全文挿入フォールバックのテストを辞書非依存にする。
final class LLMFallbackForcingMockAzoo: AzooKeyConverting, @unchecked Sendable {
    func requestCandidates(hiragana: String) -> [String] { [] }
    func commit(reading: String, text: String) {}
    func candidatesForSegment(reading: String) -> [String] { [] }
    func segmentize(_ hiragana: String) -> [(reading: String, candidates: [String])] {
        guard hiragana == "わたしはがくせい" else { return [] }
        return [
            ("わたし", []),
            ("は", []),
            ("がくせい", [])
        ]
    }
}
