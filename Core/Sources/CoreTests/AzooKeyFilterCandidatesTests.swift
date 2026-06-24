import XCTest
@testable import KeynacoCore

/// `filterCandidatesForDisplay` の regression baseline（POC260529b'）。
///
/// AzooKey は読みより長い予測補完候補も返すため、フィルタを外すと完全一致が大幅に後退する
/// （doc によれば「かくにん」→「角煮ん」が rank 1、「確認」が rank 205）。
/// このテストはフィルタを通った状態で完全一致が top に残ることを外形 pin する。
final class AzooKeyFilterCandidatesTests: XCTestCase {

    /// **不変条件回帰テスト**: 「かくにん」を変換したら「確認」が top 20 以内に出る。
    /// フィルタ削除や condition 緩和で予測補完が exact を押しのけたらここが落ちる。
    func testExactMatchSurvivesFilteringForKakunin() {
        let converter = AzooKeyConverter()
        let candidates = converter.requestCandidates(
            hiragana: "かくにん", leftSideContext: nil, richCandidates: true
        )
        guard let idx = candidates.firstIndex(where: { $0.text == "確認" }) else {
            XCTFail("「確認」が候補に含まれていない（dict 異常？）: \(candidates.texts.prefix(20))"); return
        }
        XCTAssertLessThan(
            idx, 20,
            "「確認」が top 20 外に沈んでいる。filterCandidatesForDisplay の prediction フィルタが"
            + "外れたか緩和された疑い。rank=\(idx), top20=\(candidates.texts.prefix(20))"
        )
    }
}
