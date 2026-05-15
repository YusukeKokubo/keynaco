import XCTest
@testable import KeynacoCore

// Zenzai top-1 プロモートが leftSideContext の有無で変わることを検証する。
// - 左文脈なし: azooKeyLeftContext == nil → Zenzai 未発火 → fixedEnd = kana×2
// - 左文脈あり: azooKeyLeftContext != nil → Zenzai top-1 が固定枠に昇格 → fixedEnd = kana×2 + 1
//
// AzooKeyConverter の実モデル（gguf）はテスト環境では使えないため、
// isZenzaiEnabled = true のモックで代替する。

private final class ZenzaiEnabledMockConverter: AzooKeyConverting, @unchecked Sendable {
    var isZenzaiEnabled: Bool { true }

    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        switch hiragana {
        case "かいさい": return ["開催", "快哉", "皆済", "悔斎"]
        default:        return []
        }
    }

    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        requestCandidates(hiragana: reading, leftSideContext: leftSideContext, richCandidates: false)
    }

    func commit(reading: String, text: String) {}

    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])] {
        [(reading: hiragana,
          candidates: requestCandidates(hiragana: hiragana, leftSideContext: leftSideContext, richCandidates: false))]
    }
}

final class ZenzaiLeftContextTests: XCTestCase {

    var handler: InputHandler!
    var client: MockTextClient!

    override func setUp() {
        super.setUp()
        InputHandler.isAsciiMode = false
        handler = InputHandler(db: DatabaseManager(inMemory: true),
                               azooKeyConverter: ZenzaiEnabledMockConverter())
        client = MockTextClient()
    }

    // MARK: - ヘルパー

    @discardableResult
    private func typeChar(_ ch: Character) -> CandidateAction {
        let s = String(ch)
        let ctx = CandidateContext(isVisible: false, selectedRow: 0, selectedText: nil)
        return handler.handle(keyCode: 0, characters: s, baseCharacters: s,
                              modifiers: [], candidate: ctx, client: client).candidateAction
    }

    private func typeRomaji(_ s: String) { s.forEach { typeChar($0) } }

    @discardableResult
    private func pressSpace(candidateVisible: Bool = false, selectedRow: Int = 0) -> CandidateAction {
        let ctx = CandidateContext(isVisible: candidateVisible, selectedRow: selectedRow, selectedText: nil)
        return handler.handle(keyCode: 49, characters: " ", baseCharacters: " ",
                              modifiers: [], candidate: ctx, client: client).candidateAction
    }

    @discardableResult
    private func pressEnter(candidateVisible: Bool = false, selectedRow: Int = 0,
                            selectedText: String? = nil) -> CandidateAction {
        let ctx = CandidateContext(isVisible: candidateVisible, selectedRow: selectedRow,
                                   selectedText: selectedText)
        return handler.handle(keyCode: 36, characters: "\r", baseCharacters: "\r",
                              modifiers: [], candidate: ctx, client: client).candidateAction
    }

    // MARK: - テスト

    /// 左文脈なし: Zenzai 未発火 → 辞書先頭候補 "開催" が row 0 に昇格（fixedEnd = 0）
    func testZenzaiNotPromotedWithoutLeftContext() {
        handler.leftSideContext = ""
        typeRomaji("kaisai")
        let action = pressSpace()
        guard case .show(let candidates, _, _, _, let fixedEnd) = action else {
            XCTFail("Expected .show but got \(action)"); return
        }
        XCTAssertEqual(fixedEnd, 0, "左文脈なし: 辞書先頭昇格により fixedEnd = 0")
        XCTAssertEqual(candidates[0], "開催", "辞書 top-1 が row 0 に昇格するはず")
        XCTAssertEqual(candidates[1], "かいさい")
        XCTAssertEqual(candidates[2], "カイサイ")
        XCTAssertNil(handler.lastZenzaiRow, "Zenzai 未発火なので lastZenzaiRow は nil")
    }

    /// 左文脈あり: Zenzai top-1 が固定枠に昇格 → fixedEnd = 3
    func testZenzaiPromotedWithLeftContext() {
        handler.leftSideContext = "東京で"
        typeRomaji("kaisai")
        let action = pressSpace()
        guard case .show(let candidates, _, _, _, let fixedEnd) = action else {
            XCTFail("Expected .show but got \(action)"); return
        }
        XCTAssertEqual(fixedEnd, 3, "左文脈あり: Zenzai top-1 昇格で fixedEnd = 3 のはず")
        XCTAssertEqual(candidates[0], "かいさい")
        XCTAssertEqual(candidates[1], "カイサイ")
        XCTAssertEqual(candidates[2], "開催", "Zenzai top-1 が固定枠末尾 [fixedEnd-1] に昇格するはず")
    }

    /// committedHistory から leftSideContext を構築するフロー:
    /// 「東京」「で」を確定後に leftSideContext を設定してから「かいさい」変換。
    func testZenzaiPromotedFromCommittedHistory() {
        // 「とうきょう」→ Space →「とうきょう」（モックは候補を返さないのでひらがなで確定）→ Enter
        typeRomaji("toukyou")
        pressSpace()
        pressEnter(candidateVisible: true, selectedRow: 0, selectedText: "とうきょう")
        XCTAssertEqual(handler.committedHistory, ["とうきょう"])

        // 「で」→ Enter（変換なし）
        typeRomaji("de")
        pressEnter()
        XCTAssertEqual(handler.committedHistory, ["とうきょう", "で"])

        // InputController が行うのと同じ: committedHistory → leftSideContext
        handler.leftSideContext = handler.committedHistory.suffix(5).joined()
        XCTAssertEqual(handler.leftSideContext, "とうきょうで")

        typeRomaji("kaisai")
        let action = pressSpace()
        guard case .show(let candidates, _, _, _, let fixedEnd) = action else {
            XCTFail("Expected .show but got \(action)"); return
        }
        XCTAssertEqual(fixedEnd, 3, "committedHistory 由来の左文脈で Zenzai 発火 → fixedEnd = 3")
        XCTAssertEqual(candidates[2], "開催", "Zenzai top-1「開催」が固定枠に昇格するはず")
    }
}
