import XCTest
@testable import KeynacoCore

/// `docs/domain/scenarios.md` の入力トレースを回帰用に固定化したテスト。
/// 辞書に依存しない箇所は `AzooKeyConverting` のモックで再現する。

// MARK: - S-01 用モック（2 文節に分割し「漢字」が選ばれる）

private final class ScenarioS01KanjiMockConverter: AzooKeyConverting {
    func requestCandidates(hiragana: String) -> [String] {
        hiragana == "かんじ" ? ["漢字"] : ["□"]
    }

    func candidatesForSegment(reading: String) -> [String] {
        switch reading {
        case "かん": return ["漢"]
        case "じ": return ["字"]
        default: return ["□"]
        }
    }

    func commit(reading _: String, text _: String) {}

    func segmentize(_ hiragana: String) -> [(reading: String, candidates: [String])] {
        guard hiragana == "かんじ" else {
            return [(reading: hiragana, candidates: ["□"])]
        }
        return [
            (reading: "かん", candidates: ["漢"]),
            (reading: "じ", candidates: ["字"]),
        ]
    }
}

final class ScenarioRegressionTests: InputHandlerTestCase {

    /// **S-01**: `k` `a` `n` `j` `i` Space Enter → 確定「漢字」。モックで常に 2 セグメント→セグメントモード。
    /// （実 AzooKey は 1 セグメントだと通常の候補リストにフォールバックするためモックを使用）
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
        XCTAssertTrue(h.state.isSegmentMode, "2 セグメントならセグメントモードに入るはず")
        guard case .show = spaceAction else {
            XCTFail("Space で .show を返すはず: \(spaceAction)")
            return
        }

        let (_, enterAction) = h.handle(
            keyCode: KeyCode.enter,
            characters: nil,
            baseCharacters: nil,
            modifiers: [],
            candidate: .hidden,
            client: c
        )
        XCTAssertFalse(h.state.isSegmentMode)
        XCTAssertEqual(c.inserted.last, "漢字")
        _ = enterAction
        XCTAssertTrue(h.isSuccessorMode, "「漢字」末尾は名詞扱いで格助詞フォールバック等で Successor に入るはず")
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

    /// **S-02**（参照）: `ka` の候補が開いている状態で ↓↓→ はひらがな「か」を確定。
    /// 詳細は `InputHandlerCandidatesTests.testRightArrowDuringCandidateCommitsHiragana` と同等。
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
