import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

/// AzooKey 生候補 → 画面表示までの post-processing パイプラインを通した end-to-end シナリオ集。
///
/// 加工は 8 段あり、各段の単体テストは別ファイル（`AzooKeyConverterTests` /
/// `CandidateSectionBuilderTests` / `CandidateLayoutTests` /
/// `InitialRowPolicyResolverTests` / `InputHandlerCandidatesTests` 等）にある。
/// このファイルは「全段が連動して何を生むか」を worked example として固定する。
///
/// ```
/// [1] AzooKey 内部（KanaKanjiConverter.requestCandidates）
/// [2] AzooKeyConverter.filterCandidatesForDisplay
/// [3] InputHandler.fetchAzooKeyCandidates（ラッパー、lcid ソートは P-7 で削除済）
/// [4] CandidateSectionBuilder.build
/// [5] CandidateLayout.init
/// [6] InitialRowPolicyResolver.resolve
/// [7] InitialRowPolicyResolver.whileTypingInitialRow（打鍵中のみ）
/// [8] assembleCandidateList の dismiss 条件
/// ```
///
/// AzooKey 実辞書に依存するため slow tests。テスト名の `_protects_<段名>` は
/// そのシナリオが守る加工段の主役を示す。
final class CandidatePipelineScenarioTests: InputHandlerTestCase {

    // MARK: - Helpers

    /// 組成→ Space → 候補リスト先頭近辺の text 列を返す。
    private func candidatesAfterSpace(_ romaji: String) -> [String] {
        typeRomaji(romaji)
        press(keyCode: KeyCode.space)
        return handler.candidateSession.candidates
    }

    private func selectedTextAfterSpace(_ romaji: String) -> String? {
        typeRomaji(romaji)
        press(keyCode: KeyCode.space)
        return handler.candidateSession.selectedText
    }

    // MARK: - [2] filterCandidatesForDisplay: 機械生成カタカナ・ひらがなの exact プロモート除外

    /// 長文ひらがな読みで AzooKey の機械生成カタカナが Z1 にプロモートされてはいけない。
    /// 「カクニンガヒツヨウデスネ」より前にひらがな or 漢字混じり候補が来る。
    /// （`5b192e5` で導入された除外を end-to-end で保護）
    func testKakuninLongReading_protects_filterMachineGeneratedKatakana() {
        let texts = candidatesAfterSpace("kakuninngahituyoudesune")
        guard let idxKatakana = texts.firstIndex(of: "カクニンガヒツヨウデスネ") else { return }
        XCTAssertGreaterThan(idxKatakana, 0,
            "機械生成カタカナが Z1 にプロモートされてはいけない: \(texts.prefix(5))")
    }

    /// 機械生成ひらがな（text=ひらがな, ruby=カタカナ, lcid=固有名詞）も
    /// 漢字混じり辞書候補より後ろに回る。
    /// （`ea50b1a` で導入された除外を保護）
    func testKakuninLongReading_protects_filterMachineGeneratedHiragana() {
        let texts = candidatesAfterSpace("kakuninngahituyoudesune")
        guard let idxKanji = texts.firstIndex(of: "確認が必要ですね"),
              let idxHiragana = texts.firstIndex(of: "かくにんがひつようですね") else { return }
        XCTAssertLessThan(idxKanji, idxHiragana,
            "漢字混じり辞書候補が機械生成ひらがなより前: \(texts.prefix(5))")
    }

    /// 辞書ヒットの単セグメント完全一致は依然 exact プロモートされる。
    /// 「内閣府」（ruby=ないかくふ ≠ text）は機械生成扱いされず、予測補完
    /// 「内閣府令」より前に来る。（`eb5e31b` の元の意図を保護）
    func testNaikakufuExact_protects_filterDictionaryExactPromote() {
        let texts = candidatesAfterSpace("naikakufu")
        guard let idxFu = texts.firstIndex(of: "内閣府"),
              let idxRei = texts.firstIndex(of: "内閣府令") else { return }
        XCTAssertLessThan(idxFu, idxRei,
            "辞書ヒット完全一致が予測補完より前: \(texts.prefix(5))")
    }

    // MARK: - [3] fetchAzooKeyCandidates: lcid ソートで Zenzai 順序を上書きしない

    /// 過去に lcid ソートが Zenzai の文脈推論を逆転させていたバグ（P-7）の回帰チェック。
    /// 「そうだった」入力で Zenzai がひらがなを推した順序がそのまま反映される。
    func testSoudatta_protects_noLcidSortOverride() {
        let texts = candidatesAfterSpace("soudatta")
        guard let idxHiragana = texts.firstIndex(of: "そうだった"),
              let idxKatakana = texts.firstIndex(of: "ソウダッタ") else { return }
        XCTAssertLessThan(idxHiragana, idxKatakana,
            "Zenzai が推したひらがなを lcid ソートが逆転してはいけない: \(texts.prefix(5))")
    }

    // MARK: - 短文の正常動作（パイプライン全体の sanity）

    /// 短文ひらがなで Z1 が辞書由来ひらがなのまま（機械生成除外で道連れにならない）。
    func testYabai_protects_shortReadingDictionaryHiragana() {
        let selected = selectedTextAfterSpace("yabai")
        XCTAssertEqual(selected, "やばい",
            "短文の辞書ひらがな候補は Z1 のまま")
    }
}
