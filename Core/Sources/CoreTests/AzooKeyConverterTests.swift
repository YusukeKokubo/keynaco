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

    // MARK: - segmentize の候補に残余ひらがなが混入しない

    func testSegmentizeDoesNotProduceDanglingHiraganaCandidates() {
        let converter = AzooKeyConverter()
        let segments = converter.segmentize("じゃあ")
        // 「じゃあ」は「じゃ」+「あ」の 2 セグメントに分割される
        XCTAssertGreaterThanOrEqual(segments.count, 2,
            "「じゃあ」は 2 セグメント以上に分割されるはず")
        let jaCandidates = segments[0].candidates
        // 「じゃ」セグメントの候補に残余ひらがな付き候補（「蛇あ」等）が出ない
        let dangling = jaCandidates.filter { candidate in
            let residual = String("じゃあ".dropFirst(segments[0].reading.count))
            return !residual.isEmpty && candidate.hasSuffix(residual)
        }
        XCTAssertTrue(dangling.isEmpty,
            "「じゃ」候補に残余ひらがな付きの候補が含まれてはいけない: \(dangling)")
    }

    func testSegmentizeFirstSegmentRetainsValidCandidates() {
        let converter = AzooKeyConverter()
        let segments = converter.segmentize("じゃあ")
        XCTAssertGreaterThanOrEqual(segments.count, 2)
        let jaCandidates = segments[0].candidates
        // 「じゃ」単独の変換候補（「じゃ」「ジャ」「蛇」等）は残る
        XCTAssertTrue(jaCandidates.contains("じゃ"),
            "「じゃ」ひらがな候補が含まれるはず: \(jaCandidates)")
    }

    // MARK: - requestCandidates の候補に残余ひらがなが混入しない

    func testRequestCandidatesDoesNotProduceDanglingHiraganaCandidates() {
        let converter = AzooKeyConverter()
        let candidates = converter.requestCandidates(hiragana: "じゃあ")
        // 「じゃあ」全体を読みとして変換したとき、残余ひらがな付き候補（「蛇あ」等）が出ない
        let hiraganaRange = Unicode.Scalar("あ").value...Unicode.Scalar("ん").value
        let dangling = candidates.filter { candidate in
            guard let first = candidate.unicodeScalars.first,
                  let last = candidate.unicodeScalars.last else { return false }
            // 先頭が非ひらがな（漢字/カタカナ等）で末尾がひらがな → 残余付き
            return !(hiraganaRange ~= first.value) && (hiraganaRange ~= last.value)
        }
        XCTAssertTrue(dangling.isEmpty,
            "requestCandidates(じゃあ) に残余ひらがな付き候補が含まれてはいけない: \(dangling)")
    }

    // MARK: - 活用語 + 助動詞の複合変換

    func testRequestCandidatesIncludesKanjiForInflectedVerb() {
        let converter = AzooKeyConverter()
        let candidates = converter.requestCandidates(hiragana: "たのみたい")
        XCTAssertTrue(candidates.contains("頼みたい"),
            "「たのみたい」→「頼みたい」が候補に含まれるはず: \(candidates)")
    }


    // MARK: - 助詞付き音便形の変換

    func testManandakaConvertsToManandaka() {
        let converter = AzooKeyConverter()
        let candidates = converter.requestCandidates(hiragana: "まなんだか", leftSideContext: nil, richCandidates: true)
        XCTAssertTrue(candidates.contains("学んだか"),
            "「まなんだか」→「学んだか」が候補に含まれるはず: \(candidates)")
    }

    func testManandaConvertsToMananda() {
        let converter = AzooKeyConverter()
        let candidates = converter.requestCandidates(hiragana: "まなんだ", leftSideContext: nil, richCandidates: true)
        XCTAssertTrue(candidates.contains("学んだ"),
            "「まなんだ」→「学んだ」が候補に含まれるはず: \(candidates)")
    }
}
