import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

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

    func commit(reading: String, text: String) {}
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
        guard case .show(let candidates, _, _, let fixedEnd) = action else {
            XCTFail("Expected .show but got \(action)"); return
        }
        XCTAssertEqual(fixedEnd, 0, "左文脈なし: fixedCount=0, Zenzai未発火 → fixedEnd=0")
        XCTAssertEqual(candidates[0], "開催", "辞書先頭候補が row 0")
        XCTAssertEqual(candidates[1], "快哉", "辞書2番目候補が row 1")
        XCTAssertNil(handler.lastZenzaiRow, "Zenzai 未発火なので lastZenzaiRow は nil")
    }

    /// 左文脈あり: Zenzai top-1 が固定枠に昇格 → fixedEnd = 3
    func testZenzaiPromotedWithLeftContext() {
        handler.leftSideContext = "東京で"
        typeRomaji("kaisai")
        let action = pressSpace()
        guard case .show(let candidates, _, _, let fixedEnd) = action else {
            XCTFail("Expected .show but got \(action)"); return
        }
        XCTAssertEqual(fixedEnd, 1, "左文脈あり: Zenzai top-1 昇格で fixedEnd = 1 のはず")
        XCTAssertEqual(candidates[0], "開催", "Zenzai top-1 が row 0 に昇格するはず")
    }

    /// sessionTextBuffer から leftSideContext を構築するフロー。
    func testZenzaiPromotedFromSessionTextBuffer() {
        typeRomaji("toukyou")
        pressSpace()
        pressEnter(candidateVisible: true, selectedRow: 0, selectedText: "とうきょう")
        typeRomaji("de")
        pressEnter()
        handler.leftSideContext = handler.sessionTextBuffer
        XCTAssertEqual(handler.leftSideContext, "とうきょうで")

        typeRomaji("kaisai")
        let action = pressSpace()
        guard case .show(let candidates, _, _, let fixedEnd) = action else {
            XCTFail("Expected .show but got \(action)"); return
        }
        XCTAssertEqual(fixedEnd, 1, "sessionTextBuffer 由来の左文脈で Zenzai 発火 → fixedEnd = 1")
        XCTAssertEqual(candidates[0], "開催", "Zenzai top-1「開催」が row 0 に昇格するはず")
    }

    func testSessionBufferPersistsAcrossSentenceBoundary() {
        handler.commitText(text: "報告", client: client)
        handler.commitText(text: "。", client: client)
        XCTAssertTrue(handler.committedHistory.isEmpty)
        XCTAssertFalse(handler.sessionTextBuffer.isEmpty, "文末後も sessionTextBuffer は残る")
    }
}
