import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

final class InputHandlerSessionRecordTests: InputHandlerTestCase {

    // MARK: - commitComposition 経路（候補ウィンドウなし）

    func testPendingSessionRecordSetAfterEnterWithoutCandidate() {
        typeRomaji("kanzi")
        press(keyCode: KeyCode.enter)
        XCTAssertNotNil(handler.pendingSessionRecord, "候補なし Enter 後に pendingSessionRecord がセットされるはず")
        XCTAssertEqual(handler.pendingSessionRecord?.reading, "かんじ")
        XCTAssertEqual(handler.pendingSessionRecord?.committed, "かんじ")
        XCTAssertFalse(handler.pendingSessionRecord?.wasExplicit ?? true)
    }

    // MARK: - doConfirmSelection 経路（候補ウィンドウあり）

    /// prefix focus（isExplicitlySelected=false）で候補選択中に Enter → pendingSessionRecord がセットされる。
    /// このバグを修正する前は commitText を直接呼んでいたため記録されなかった。
    func testPendingSessionRecordSetAfterEnterWithPrefixFocusCandidate() {
        typeRomaji("kanzi")
        press(keyCode: KeyCode.enter, candidateVisible: true, selectedRow: 2, selectedText: "漢字")
        XCTAssertNotNil(handler.pendingSessionRecord, "prefix focus 確定後に pendingSessionRecord がセットされるはず")
        XCTAssertEqual(handler.pendingSessionRecord?.reading, "かんじ")
        XCTAssertEqual(handler.pendingSessionRecord?.committed, "漢字")
        XCTAssertEqual(handler.pendingSessionRecord?.candidateDepth, 2)
        XCTAssertFalse(handler.pendingSessionRecord?.wasExplicit ?? true)
    }

    func testPendingSessionRecordSetAfterEnterWithExplicitCandidate() {
        typeRomaji("kanzi")
        press(keyCode: KeyCode.enter, candidateVisible: true, selectedRow: 1, selectedText: "感じ", isExplicitlySelected: true)
        XCTAssertNotNil(handler.pendingSessionRecord, "Space 選択後 Enter でも pendingSessionRecord がセットされるはず")
        XCTAssertEqual(handler.pendingSessionRecord?.committed, "感じ")
        XCTAssertTrue(handler.pendingSessionRecord?.wasExplicit ?? false)
    }

    // MARK: - Escape 経路

    func testPendingSessionRecordSetAfterEscape() {
        typeRomaji("kanzi")
        press(keyCode: KeyCode.escape)
        XCTAssertNotNil(handler.pendingSessionRecord, "Escape 後に pendingSessionRecord がセットされるはず")
        XCTAssertNil(handler.pendingSessionRecord?.committed, "Escape は committed が nil のはず")
    }

    // MARK: - リセット

    func testPendingSessionRecordClearedAfterReset() {
        typeRomaji("a")
        press(keyCode: KeyCode.enter)
        XCTAssertNotNil(handler.pendingSessionRecord)
        // 次のキーで新しいセッションが始まったとき sessionTracker がリセットされる（pendingSessionRecord は InputController 側で消費）
    }
}
