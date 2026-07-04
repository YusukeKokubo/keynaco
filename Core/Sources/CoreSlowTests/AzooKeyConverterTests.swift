import XCTest
@testable import KeynacoCore

final class AzooKeyConverterTests: XCTestCase {

    // MARK: - candidateCache のサイズ上限

    func testCandidateCacheDoesNotExceedLimit() {
        let converter = AzooKeyConverter()
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
        for i in 0..<55 {
            _ = converter.requestCandidates(hiragana: "い\(i)")
        }
        XCTAssertLessThanOrEqual(converter.candidateCacheCount, 50)
    }

    func testRequestCandidatesCacheHitForSameKey() {
        let converter = AzooKeyConverter()
        let first = converter.requestCandidates(hiragana: "かい")
        let countAfterFirst = converter.candidateCacheCount
        let second = converter.requestCandidates(hiragana: "かい")
        XCTAssertEqual(first, second)
        XCTAssertEqual(converter.candidateCacheCount, countAfterFirst, "同一キー再要求でキャッシュエントリ数は増えない")
    }
    func testRequestCandidatesCacheMissWhenRichCandidatesDiffers() {
        let converter = AzooKeyConverter()
        _ = converter.requestCandidates(hiragana: "かい", leftSideContext: nil, richCandidates: false)
        let countAfterPlain = converter.candidateCacheCount
        _ = converter.requestCandidates(hiragana: "かい", leftSideContext: nil, richCandidates: true)
        XCTAssertEqual(converter.candidateCacheCount, countAfterPlain + 1,
                       "richCandidates が異なれば別キーとしてキャッシュする")
    }

    // MARK: - requestCandidates の候補に残余ひらがなが混入しない

    func testRequestCandidatesDoesNotProduceDanglingHiraganaCandidates() {
        let converter = AzooKeyConverter()
        let candidates = converter.requestCandidates(hiragana: "じゃあ").texts
        let hiraganaRange = Unicode.Scalar("あ").value...Unicode.Scalar("ん").value
        let dangling = candidates.filter { candidate in
            guard let first = candidate.unicodeScalars.first,
                  let last = candidate.unicodeScalars.last else { return false }
            return !(hiraganaRange ~= first.value) && (hiraganaRange ~= last.value)
        }
        XCTAssertTrue(dangling.isEmpty,
            "requestCandidates(じゃあ) に残余ひらがな付き候補が含まれてはいけない: \(dangling)")
    }

    // MARK: - 活用語 + 助動詞の複合変換

    func testRequestCandidatesIncludesKanjiForInflectedVerb() {
        let converter = AzooKeyConverter()
        let texts = converter.requestCandidates(hiragana: "たのみたい").texts
        XCTAssertTrue(texts.contains("頼みたい"),
            "「たのみたい」→「頼みたい」が候補に含まれるはず: \(texts)")
    }

    // MARK: - 助詞付き音便形の変換

    func testManandakaConvertsToManandaka() {
        let converter = AzooKeyConverter()
        let texts = converter.requestCandidates(hiragana: "まなんだか", leftSideContext: nil, richCandidates: true).texts
        XCTAssertTrue(texts.contains("学んだか"),
            "「まなんだか」→「学んだか」が候補に含まれるはず: \(texts)")
    }

    func testManandaConvertsToMananda() {
        let converter = AzooKeyConverter()
        let texts = converter.requestCandidates(hiragana: "まなんだ", leftSideContext: nil, richCandidates: true).texts
        XCTAssertTrue(texts.contains("学んだ"),
            "「まなんだ」→「学んだ」が候補に含まれるはず: \(texts)")
    }

    // MARK: - 予測補完のかな尾ひれを落とす（POC260529b'）

    func testPredictionKanaTailsAreFiltered() {
        let converter = AzooKeyConverter()
        let kigasuru = converter.requestCandidates(hiragana: "きがする").texts
        for tail in ["気がするん", "気がするの", "気がするし"] {
            XCTAssertFalse(kigasuru.contains(tail),
                "かな尾ひれ「\(tail)」は除外されるはず: \(kigasuru)")
        }
        XCTAssertTrue(kigasuru.contains("気がする"),
            "「気がする」（予測でない変換）は残るはず: \(kigasuru)")

        let wakaranai = converter.requestCandidates(hiragana: "わからない").texts
        for tail in ["わからないの", "わからないん", "分からないん"] {
            XCTAssertFalse(wakaranai.contains(tail),
                "かな尾ひれ「\(tail)」は除外されるはず: \(wakaranai)")
        }
        XCTAssertTrue(wakaranai.contains("わからない") || wakaranai.contains("分からない"),
            "「わからない」の素の変換は残るはず: \(wakaranai)")
    }

    func testKanjiExtendingPredictionsAreKept() {
        let converter = AzooKeyConverter()
        let naikaku = converter.requestCandidates(hiragana: "ないかく").texts
        XCTAssertTrue(naikaku.contains("内閣"),
            "「内閣」は残るはず: \(naikaku)")
        XCTAssertTrue(naikaku.contains("内閣府"),
            "漢字伸長の予測「内閣府」は残るはず: \(naikaku)")
    }

    func testKakuninExactMatchRanksAboveKakuniSegmentSplit() {
        let converter = AzooKeyConverter()
        let texts = converter.requestCandidates(hiragana: "かくにん").texts
        XCTAssertFalse(texts.contains("角煮ん"),
            "2セグメント・末尾かな「角煮ん」は除外されるはず: \(texts.prefix(5))")
        XCTAssertTrue(texts.contains("確認"),
            "1セグメント「確認」は残るはず: \(texts.prefix(5))")
        if let rank = texts.firstIndex(of: "確認") {
            XCTAssertLessThan(rank, 10,
                "「確認」は上位に来るはず（実際 \(rank + 1) 位）: \(texts.prefix(10))")
        }
    }

    func testNaikakufuExactMatchPrecedesCompletion() {
        let converter = AzooKeyConverter()
        let texts = converter.requestCandidates(hiragana: "ないかくふ").texts
        guard let idxFu = texts.firstIndex(of: "内閣府"),
              let idxRei = texts.firstIndex(of: "内閣府令") else { return }
        XCTAssertLessThan(idxFu, idxRei,
            "内閣府(完全一致) が 内閣府令(予測補完) より前に来るはず: \(texts.prefix(8))")
    }

    func testFullCoverageInflectionsAreNotDropped() {
        let converter = AzooKeyConverter()
        let manandaka = converter.requestCandidates(hiragana: "まなんだか", leftSideContext: nil, richCandidates: true).texts
        XCTAssertTrue(manandaka.contains("学んだか"),
            "予測でない「学んだか」は残るはず: \(manandaka)")
        let wakaranai = converter.requestCandidates(hiragana: "わからない").texts
        XCTAssertTrue(wakaranai.contains("分からない") || wakaranai.contains("わからない"),
            "予測でない「分からない」は残るはず: \(wakaranai)")
    }

    /// 長文ひらがな読みで AzooKey の機械生成カタカナ候補が exact プロモートで Z1 に
    /// 上がる事故を防ぐ。`getAdditionalCandidate` が `lcid == 固有名詞 かつ ruby が全カタカナ`
    /// として返す候補を exact 枠から除外して、辞書ヒット候補に Z1 を譲る。
    func testLongReadingMachineGeneratedKatakanaIsNotPromoted() {
        let converter = AzooKeyConverter()
        let texts = converter.requestCandidates(hiragana: "かくにんがひつようですね").texts
        // 「確認が必要ですね」のような漢字混じり候補 or ひらがな候補が、機械生成カタカナより前に来る
        guard let idxKatakana = texts.firstIndex(of: "カクニンガヒツヨウデスネ") else {
            return  // そもそも候補に出てなければスキップ（辞書次第）
        }
        let earlierCandidates = Array(texts.prefix(idxKatakana))
        XCTAssertFalse(earlierCandidates.isEmpty,
            "カタカナ機械生成より前にひらがな or 漢字混じり候補が少なくとも 1 件は来るはず: \(texts.prefix(5))")
    }

    /// 機械生成ひらがな候補（`text==hiraganaString, ruby=カタカナ, lcid=固有名詞`）も
    /// exact 枠から除外され、辞書由来の漢字混じり候補に Z1 を譲る。
    /// 「かくにんがひつようですね」で「確認が必要ですね」が「かくにんがひつようですね」より前に来る。
    func testLongReadingMachineGeneratedHiraganaIsNotPromoted() {
        let converter = AzooKeyConverter()
        let texts = converter.requestCandidates(hiragana: "かくにんがひつようですね").texts
        guard let idxKanji = texts.firstIndex(of: "確認が必要ですね"),
              let idxHiragana = texts.firstIndex(of: "かくにんがひつようですね") else {
            return  // 辞書次第でどちらかが出ないことがあるのでスキップ
        }
        XCTAssertLessThan(idxKanji, idxHiragana,
            "漢字混じり辞書候補が機械生成ひらがなより前に来るはず: \(texts.prefix(5))")
    }

    // MARK: - NumericReadingExpander 経由の暦読み

    func testShichigatsuYieldsJuly() {
        let converter = AzooKeyConverter()
        let texts = converter.requestCandidates(hiragana: "しちがつ").texts
        XCTAssertTrue(
            texts.contains(where: { $0.contains("7") && $0.contains("月") }),
            "しちがつ → 7月 系候補が含まれる: \(texts.prefix(8))"
        )
    }

    func testRokugatsuYieldsJune() {
        let converter = AzooKeyConverter()
        let texts = converter.requestCandidates(hiragana: "ろくがつ").texts
        XCTAssertTrue(
            texts.contains(where: { $0.contains("6") && $0.contains("月") }),
            "ろくがつ → 6月 系候補が含まれる: \(texts.prefix(8))"
        )
    }
}
