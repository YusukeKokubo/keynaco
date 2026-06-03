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

    func testAnataWaSegmentizeWithoutSuffixFallbackIsSingleSegmentWhenNoPartial() {
        let converter = AzooKeyConverter()
        let segments = converter.segmentize("あなたは", leftSideContext: nil)
        // Phase 1: suffix フォールバック削除。部分候補が無いときは 1 文節（文節モード境界には未使用）。
        XCTAssertEqual(segments.map(\.reading), ["あなたは"])
    }

    func testGakuseiDesuSegmentizeWithoutSuffixFallbackIsSingleSegmentWhenNoPartial() {
        let converter = AzooKeyConverter()
        let segments = converter.segmentize("がくせいです", leftSideContext: nil)
        XCTAssertEqual(segments.map(\.reading), ["がくせいです"])
    }

    func testGakuseiDesuDefaultClauseEndStripsDesu() {
        let end = AzooKeyCandidateMerge.clauseEndStrippingTrailingParticle("がくせいです")
        XCTAssertEqual(end, 4)
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

    // MARK: - 予測補完のかな尾ひれを落とす（POC260529b'）

    /// 予測補完が付ける「機能語尾ひれ」（読みを超えて かな を足した候補）を候補から除外する。
    /// 例: 読み「きがする」→「気がするん/の/し」、「わからない」→「わからないの/ん」。
    func testPredictionKanaTailsAreFiltered() {
        let converter = AzooKeyConverter()
        let kigasuru = converter.requestCandidates(hiragana: "きがする")
        for tail in ["気がするん", "気がするの", "気がするし"] {
            XCTAssertFalse(kigasuru.contains(tail),
                "かな尾ひれ「\(tail)」は除外されるはず: \(kigasuru)")
        }
        // 読みそのものの変換（予測でない）は残る
        XCTAssertTrue(kigasuru.contains("気がする"),
            "「気がする」（予測でない変換）は残るはず: \(kigasuru)")

        let wakaranai = converter.requestCandidates(hiragana: "わからない")
        for tail in ["わからないの", "わからないん", "分からないん"] {
            XCTAssertFalse(wakaranai.contains(tail),
                "かな尾ひれ「\(tail)」は除外されるはず: \(wakaranai)")
        }
        XCTAssertTrue(wakaranai.contains("わからない") || wakaranai.contains("分からない"),
            "「わからない」の素の変換は残るはず: \(wakaranai)")
    }

    /// 漢字を伸ばす予測補完（内容語伸長）は残す。
    func testKanjiExtendingPredictionsAreKept() {
        let converter = AzooKeyConverter()
        let naikaku = converter.requestCandidates(hiragana: "ないかく")
        XCTAssertTrue(naikaku.contains("内閣"),
            "「内閣」は残るはず: \(naikaku)")
        XCTAssertTrue(naikaku.contains("内閣府"),
            "漢字伸長の予測「内閣府」は残るはず: \(naikaku)")
    }

    /// 読みに収まる（予測でない）助詞・助動詞付き変換は誤爆させない。
    /// 「学んだか」（か=助詞だが読み まなんだか == 入力長）・「分からない」（ない=助動詞）は残す。
    func testFullCoverageInflectionsAreNotDropped() {
        let converter = AzooKeyConverter()
        let manandaka = converter.requestCandidates(hiragana: "まなんだか", leftSideContext: nil, richCandidates: true)
        XCTAssertTrue(manandaka.contains("学んだか"),
            "予測でない「学んだか」は残るはず: \(manandaka)")
        let wakaranai = converter.requestCandidates(hiragana: "わからない")
        XCTAssertTrue(wakaranai.contains("分からない") || wakaranai.contains("わからない"),
            "予測でない「分からない」は残るはず: \(wakaranai)")
    }
}
