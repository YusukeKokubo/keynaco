import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

// assembleCandidateList のリファクタ前後で候補リスト構造が変わっていないことを保証する。
// PLAN260519 参照。

final class InputHandlerCandidateSnapshotTests: InputHandlerTestCase {

    private var stub: SnapStub!

    private func useStub(_ stub: SnapStub) {
        self.stub = stub
        setUpWithConverter(stub)
    }

    private func assertLayout(
        _ action: CandidateAction,
        candidates: [String], fixedEnd: Int, initialRow: Int,
        file: StaticString = #file, line: UInt = #line
    ) {
        guard let p = action.showPayload else {
            XCTFail("Expected .show but got \(action)", file: file, line: line); return
        }
        XCTAssertEqual(p.candidates, candidates, "candidates", file: file, line: line)
        XCTAssertEqual(p.fixedEnd, fixedEnd, "fixedEnd", file: file, line: line)
        XCTAssertEqual(p.initialRow, initialRow, "initialRow", file: file, line: line)
    }

    // MARK: - A: 基本ケース（固定セクションなし）

    func testSnap_A1_BareAzooKeyOnly() {
        useStub(SnapStub(["辞書A", "辞書B"]))
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["辞書A", "辞書B"],
                     fixedEnd: 0, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    func testSnap_A2_OneHighHistory() {
        useStub(SnapStub(["辞書A", "辞書B"]))
        handler.db.record(input: "あい", output: "愛")
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["愛", "辞書A", "辞書B"],
                     fixedEnd: 0, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    func testSnap_A3_ThreeHighHistories() {
        useStub(SnapStub(["辞書A", "辞書B"]))
        let t = Int64(1_000_000_000)
        handler.db.clock = { t };     handler.db.record(input: "あい", output: "愛知")
        handler.db.clock = { t + 1 }; handler.db.record(input: "あい", output: "愛媛")
        handler.db.clock = { t + 2 }; handler.db.record(input: "あい", output: "愛情")
        handler.db.clock = { t + 3 }
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["愛情", "愛媛", "愛知", "辞書A", "辞書B"],
                     fixedEnd: 0, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    func testSnap_A4_LowHistoryOnly() {
        useStub(SnapStub(["辞書A", "辞書B"]))
        let t = Int64(1_000_000_000)
        handler.db.clock = { t }
        handler.db.record(input: "あい", output: "哀")
        handler.db.clock = { t + 40 * 86400 }
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["辞書A", "辞書B"],
                     fixedEnd: 0, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    func testSnap_A5_HighAndLowHistory() {
        useStub(SnapStub(["辞書A", "辞書B"]))
        let t = Int64(1_000_000_000)
        handler.db.clock = { t }
        handler.db.record(input: "あい", output: "哀")
        handler.db.clock = { t + 40 * 86400 }
        handler.db.record(input: "あい", output: "愛")
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["愛", "辞書A", "辞書B"],
                     fixedEnd: 0, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    // MARK: - C: hiraganaPreferred

    func testSnap_C1_HiraganaPreferredNoHistory() {
        useStub(SnapStub(["辞書A", "辞書B"]))
        typeRomaji("no")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["の", "辞書A", "辞書B"],
                     fixedEnd: 1, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    func testSnap_C2_HiraganaPreferredWrongHistory() {
        useStub(SnapStub(["辞書A", "辞書B"]))
        handler.db.record(input: "の", output: "ノックアウト")
        typeRomaji("no")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["の", "ノックアウト", "辞書A", "辞書B"],
                     fixedEnd: 1, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    func testSnap_C3_HiraganaPreferredHiraganaInHistory() {
        useStub(SnapStub(["辞書A", "辞書B"]))
        handler.db.record(input: "の", output: "の")
        typeRomaji("no")
        // 履歴の `の` は hiragana bonus で先取りされ、layout dedup で
        // exactMatchHistory 側は脱落。fixedEnd=1 で hiragana 行のみ fixed 範囲。
        // 第一行の `の` は Shift+Delete 不可。
        assertLayout(handler.buildCandidateList(),
                     candidates: ["の", "辞書A", "辞書B"],
                     fixedEnd: 1, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    func testSnap_C4_HiraganaPreferredWithUserDict() {
        useStub(SnapStub(["辞書A", "辞書B"]))
        handler.db.addUserDict(input: "とか", output: "UD戸籍")
        typeRomaji("toka")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["とか", "UD戸籍", "辞書A", "辞書B"],
                     fixedEnd: 1, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    // MARK: - D: 長音符・小母音を含む読み（カタカナ先頭固定の特別扱いはしない）

    func testSnap_D1_LongVowelNoHistory() {
        useStub(SnapStub(["辞書A", "辞書B"]))
        type(chars: "t", base: "t"); type(chars: "o", base: "o")
        type(chars: "-", base: "-")
        type(chars: "t", base: "t"); type(chars: "a", base: "a")
        type(chars: "r", base: "r"); type(chars: "u", base: "u")
        XCTAssertEqual(handler.state.composedHiragana, "とーたる")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["辞書A", "辞書B"],
                     fixedEnd: 0, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    func testSnap_D2_LongVowelKatakanaInHistory() {
        useStub(SnapStub(["辞書A", "辞書B"]))
        handler.db.record(input: "とーたる", output: "トータル")
        type(chars: "t", base: "t"); type(chars: "o", base: "o")
        type(chars: "-", base: "-")
        type(chars: "t", base: "t"); type(chars: "a", base: "a")
        type(chars: "r", base: "r"); type(chars: "u", base: "u")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["トータル", "辞書A", "辞書B"],
                     fixedEnd: 0, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    func testSnap_D3_SmallVowelNoHistory() {
        useStub(SnapStub(["辞書A", "辞書B"]))
        type(chars: "n", base: "n"); type(chars: "e", base: "e"); type(chars: "i", base: "i")
        type(chars: "t", base: "t"); type(chars: "h", base: "h"); type(chars: "i", base: "i")
        type(chars: "b", base: "b"); type(chars: "u", base: "u")
        XCTAssertEqual(handler.state.composedHiragana, "ねいてぃぶ")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["辞書A", "辞書B"],
                     fixedEnd: 0, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    // MARK: - E: ユーザー辞書

    func testSnap_E1_UserDictOnly() {
        useStub(SnapStub(["辞書A", "辞書B"]))
        handler.db.addUserDict(input: "あい", output: "Acme")
        typeRomaji("ai")
        // ユーザー辞書 exact は履歴 exact と同等扱いで初期選択される。
        assertLayout(handler.buildCandidateList(),
                     candidates: ["Acme", "辞書A", "辞書B"],
                     fixedEnd: 0, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    func testSnap_E2_UserDictWithHighHistory() {
        useStub(SnapStub(["辞書A", "辞書B"]))
        handler.db.addUserDict(input: "あい", output: "Acme")
        handler.db.record(input: "あい", output: "愛")
        typeRomaji("ai")
        // PLAN260624b/c: userDict exact が score 順で row 0
        assertLayout(handler.buildCandidateList(),
                     candidates: ["Acme", "愛", "辞書A", "辞書B"],
                     fixedEnd: 0, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    func testSnap_E3_UserDictDedupedWhenInAzooKey() {
        useStub(SnapStub(["Acme", "辞書B"]))
        handler.db.addUserDict(input: "あい", output: "Acme")
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["Acme", "辞書B"],
                     fixedEnd: 0, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    // MARK: - G: 数値・日時候補

    func testSnap_G1_NumberCandidates() {
        useStub(SnapStub([]))
        type(chars: "1", base: "1"); type(chars: "2", base: "2")
        type(chars: "3", base: "3"); type(chars: "4", base: "4")
        XCTAssertEqual(handler.state.composedHiragana, "1234")
        assertLayout(handler.buildCandidateList(),
                     candidates: ["1234", "１２３４", "1,234", "１，２３４"],
                     fixedEnd: 0, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }

    func testSnap_G2_DateTimeCandidatesSortedByScore() {
        useStub(SnapStub(["今日", "本日"]))
        typeRomaji("kyou")
        let action = handler.buildCandidateList()
        guard let p = action.showPayload else {
            XCTFail(".show を返すはず"); return
        }
        let expectedDates = InputHandler.generateDateTimeCandidates(for: "きょう")
        XCTAssertFalse(expectedDates.isEmpty, "日時候補が生成されるはず")
        XCTAssertTrue(p.candidates.contains("今日"))
        XCTAssertTrue(p.candidates.contains("本日"))
        for date in expectedDates {
            XCTAssertTrue(p.candidates.contains(date), "日時候補 \(date) が載るはず")
        }
        // AzooKey rank0(10) > 日時(5)。スコア順 flatten で辞書候補が日時より前に来うる。
        if let idxToday = p.candidates.firstIndex(of: "今日"),
           let idxFirstDate = expectedDates.compactMap({ p.candidates.firstIndex(of: $0) }).min() {
            XCTAssertLessThan(idxToday, idxFirstDate, "辞書の「今日」は日時候補より前: \(p.candidates)")
        }
        assertInjectPathMatchesSync(stub: stub)
    }

    // MARK: - H: whileTyping

    func testSnap_H1_AutoShowDismissWhenEmpty() {
        useStub(SnapStub([]))
        typeRomaji("ai")
        guard case .dismiss = handler.buildCandidateList(trigger: .whileTyping) else {
            XCTFail("候補ゼロの whileTyping は .dismiss を返すはず"); return
        }
        assertInjectPathMatchesSync(stub: stub, trigger: .whileTyping)
    }

    func testSnap_H2_AutoShowShowsWithHistory() {
        useStub(SnapStub([]))
        handler.db.record(input: "あい", output: "愛")
        typeRomaji("ai")
        assertLayout(handler.buildCandidateList(trigger: .whileTyping),
                     candidates: ["愛"],
                     fixedEnd: 0, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub, trigger: .whileTyping)
    }

    // MARK: - I: 全セクション組み合わせ

    func testSnap_I1_AllSectionsCombined() {
        let t = Int64(1_000_000_000)
        useStub(SnapStub(["辞書A"]))
        handler.db.clock = { t }
        handler.db.record(input: "あい", output: "哀")
        handler.db.clock = { t + 40 * 86400 }
        handler.db.record(input: "あい", output: "愛")
        handler.db.addUserDict(input: "あい", output: "UD合い")
        typeRomaji("ai")
        // PLAN260624b: userDict exact が score 順で履歴 exact より上
        assertLayout(handler.buildCandidateList(),
                     candidates: ["UD合い", "愛", "辞書A"],
                     fixedEnd: 0, initialRow: 0)
        assertInjectPathMatchesSync(stub: stub)
    }
}
