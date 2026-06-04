import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

/// `docs/domain/scenarios.md` の入力トレースを回帰用に固定化したテスト。
/// 辞書に依存しない箇所は `AzooKeyConverting` のモックで再現する。
/// 文節境界（AzooKey 実エンジン）は `SegmentBoundaryComparisonTests` / `InputHandlerSegmentTests` を参照（PLAN260603）。

// MARK: - S-01 用モック（3 文字語は通常窓。候補に「漢字」のみ返す）

private final class ScenarioS01KanjiMockConverter: AzooKeyConverting {
    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        _ = (leftSideContext, richCandidates)
        return hiragana == "かんじ" ? ["漢字"] : ["□"]
    }

    func requestConversionResult(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool,
        resetEngineSession: Bool
    ) -> AzooKeyConversionResult {
        _ = (leftSideContext, richCandidates, resetEngineSession)
        guard hiragana == "かんじ" else {
            return AzooKeyConversionResult(mainResults: [], firstClauseResults: [])
        }
        return AzooKeyConversionResult(
            mainResults: [AzooKeyClauseCandidate(text: "漢字", inputLength: 3)],
            firstClauseResults: [AzooKeyClauseCandidate(text: "漢", inputLength: 2)]
        )
    }

    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        _ = (reading, leftSideContext)
        return ["□"]
    }

    func commit(reading _: String, text _: String) {}

    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])] {
        _ = (hiragana, leftSideContext)
        return []
    }
}

final class ScenarioRegressionTests: InputHandlerTestCase {

    /// **S-01**: `k` `a` `n` `j` `i` Space Enter → 確定「漢字」。
    /// 3 文字語は残り 1 文字が語の一部なら文節分割せず通常窓（実 AzooKey 同様）。
    func testS01_kanji_space_enter_insertsKanji() {
        InputHandler.isAsciiMode = false
        let mock = ScenarioS01KanjiMockConverter()
        var h = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: mock)
        let c = MockTextClient()

        for ch in "kanji" {
            _ = h.handle(
                keyCode: 0,
                characters: String(ch),
                baseCharacters: String(ch),
                modifiers: [],
                candidate: .hidden,
                client: c
            )
        }
        XCTAssertEqual(h.state.composedHiragana, "かんじ")

        let (_, spaceAction) = h.handle(
            keyCode: KeyCode.space,
            characters: nil,
            baseCharacters: nil,
            modifiers: [],
            candidate: .hidden,
            client: c
        )
        XCTAssertFalse(h.state.isSegmentMode, "3 文字語は通常窓へフォールバック")
        guard case .show = spaceAction else {
            XCTFail("Space で .show を返すはず: \(spaceAction)")
            return
        }

        _ = h.handle(
            keyCode: KeyCode.enter,
            characters: nil,
            baseCharacters: nil,
            modifiers: [],
            candidate: CandidateContext(isVisible: true, selectedRow: 0, selectedText: "漢字"),
            client: c
        )
        XCTAssertFalse(h.state.isSegmentMode)
        XCTAssertEqual(c.inserted.joined(), "漢字")
    }

    /// **S-04**: `t` Shift+`O` Shift+`K` `y` `o` Enter → `tOKyo`（シナリオ記載の混在大文字トレース）
    func testS04_tShiftOShiftKyo_enter_insertsTokyoStyleWord() {
        InputHandler.isAsciiMode = false
        type(chars: "t", base: "t")
        type(chars: "O", base: "o", modifiers: .shift)
        type(chars: "K", base: "k", modifiers: .shift)
        type(chars: "y", base: "y")
        type(chars: "o", base: "o")
        press(keyCode: KeyCode.enter)
        XCTAssertEqual(client.inserted, ["tOKyo"])
    }

    func testS02_trace_ka_down_down_right_confirms_hiragana() {
        typeRomaji("ka")
        _ = press(keyCode: KeyCode.downArrow, candidateVisible: true)
        _ = press(keyCode: KeyCode.downArrow, candidateVisible: true)
        let result = press(
            keyCode: KeyCode.rightArrow,
            candidateVisible: true,
            selectedText: "花"
        )
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(client.inserted, ["か"])
    }
}
