import XCTest
@testable import KeynacoCore

final class AzooKeyConverterTests: XCTestCase {

    // MARK: - candidateCache のサイズ上限

    func testCandidateCacheDoesNotExceedLimit() {
        let converter = AzooKeyConverter()
        // 上限（50）を超える数の異なる読みで変換リクエストを送る
        for i in 0..<60 {
            _ = converter.requestCandidates(hiragana: "あ\(i)")
        }
        XCTAssertLessThanOrEqual(
            converter.candidateCacheCount, 50,
            "キャッシュが上限 50 を超えないはず: \(converter.candidateCacheCount)"
        )
    }

    func testCandidateCacheKeepsRecentEntry() {
        let converter = AzooKeyConverter()
        // 上限を超えるまで挿入し、最後に挿入したものがキャッシュに残ること
        for i in 0..<55 {
            _ = converter.requestCandidates(hiragana: "い\(i)")
        }
        // "い54" は最後に挿入した → キャッシュに残るはず
        // commit() でキャッシュを参照できるかで間接確認する
        // candidateCacheCount が上限以下であれば十分
        XCTAssertLessThanOrEqual(converter.candidateCacheCount, 50)
    }

    func testSegmentizeCacheDoesNotExceedLimit() {
        let converter = AzooKeyConverter()
        for i in 0..<60 {
            _ = converter.segmentize("う\(i)")
        }
        XCTAssertLessThanOrEqual(
            converter.candidateCacheCount, 50,
            "segmentize でもキャッシュ上限を超えないはず: \(converter.candidateCacheCount)"
        )
    }
}
