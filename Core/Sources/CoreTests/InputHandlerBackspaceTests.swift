import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

/// `doBackspace` のリグレッション。
///
/// 不変条件: 組成中 BS は常に `.whileTyping` で rebuild する。
/// `.explicit` のまま rebuild すると `selectedRow=0` で別語に強制スナップし
/// marked text がちらつく（例: 幹事 row=1 → BS → 間 row=0 が即 marked される）。
final class InputHandlerBackspaceTests: InputHandlerTestCase {

    func testBackspaceDemotesExplicitSelectionToPassive() {
        typeRomaji("kanzi")
        applyCandidateAction(handler.buildCandidateList(trigger: .explicit))
        XCTAssertTrue(handler.candidateSession.isExplicitlySelected, "Space 直後は explicit")

        let (consumed, _) = press(keyCode: KeyCode.backspace,
                                  candidateVisible: true,
                                  isExplicitlySelected: true)
        XCTAssertTrue(consumed)
        XCTAssertFalse(
            handler.candidateSession.isExplicitlySelected,
            "BS 後は passive に降格（explicit を維持すると selectedRow=0 で別語に強制スナップする）"
        )
    }

    func testBackspaceRebuildUsesWhileTypingTrigger() {
        typeRomaji("kanzi")
        applyCandidateAction(handler.buildCandidateList(trigger: .explicit))

        let (_, action) = handler.handle(
            keyCode: KeyCode.backspace, characters: nil, baseCharacters: nil,
            modifiers: [],
            candidate: CandidateContext(isVisible: true, selectedRow: 1,
                                        selectedText: nil,
                                        isExplicitlySelected: true),
            client: client
        )
        guard let payload = action.showPayload else {
            XCTFail("BS 後 composedHiragana.count>=2 なら .show を返すはず: \(action)"); return
        }
        XCTAssertFalse(
            payload.initialIsExplicitlySelected,
            ".whileTyping rebuild なので initialIsExplicitlySelected=false（=passive）"
        )
    }

    func testBackspaceKeepsMarkedTextAsHiragana() {
        // explicit "漢字" (row=0) → BS → marked text は "かん"（ひらがな）に落ち着くべき。
        // 修正前は "間"（row=0 の別語）がそのまま marked されてちらついた。
        typeRomaji("kanzi")
        applyCandidateAction(handler.buildCandidateList(trigger: .explicit))
        XCTAssertEqual(client.markedText, handler.candidateSession.selectedText ?? "",
                       "explicit 時は selectedText が marked される")

        press(keyCode: KeyCode.backspace,
              candidateVisible: true,
              isExplicitlySelected: true)
        XCTAssertEqual(client.markedText, "かん",
                       "BS 後は passive で markedText がひらがな組成に戻る")
    }

    func testBackspacePreservesPassiveMode() {
        // passive 候補表示中の BS は passive のまま（explicit に昇格しない）。
        typeRomaji("kanzi")
        applyCandidateAction(handler.buildCandidateList(trigger: .whileTyping))
        XCTAssertTrue(handler.candidateSession.isVisible)
        XCTAssertFalse(handler.candidateSession.isExplicitlySelected, "打鍵中 rebuild は passive")

        let (consumed, _) = press(keyCode: KeyCode.backspace,
                                  candidateVisible: true,
                                  isExplicitlySelected: false)
        XCTAssertTrue(consumed)
        XCTAssertFalse(handler.candidateSession.isExplicitlySelected, "BS 後も passive")
    }

    func testBackspaceShrinkingToOneCharKeepsCandidatesVisible() {
        // 2 char passive → BS で 1 char になっても候補窓は維持する。
        // 修正前は state.backspace() の needsRefresh が `>=2` で false を返し dismiss されていた
        // （「BS で候補が突然消える」体感の正体）。今は composedHiragana が残る限り rebuild。
        typeRomaji("ari")  // composedHiragana="あり"
        applyCandidateAction(handler.buildCandidateList(trigger: .whileTyping))
        XCTAssertTrue(handler.candidateSession.isVisible)

        let (consumed, action) = press(keyCode: KeyCode.backspace,
                                       candidateVisible: true)
        XCTAssertTrue(consumed)
        XCTAssertEqual(handler.state.composedHiragana, "あ")
        guard case .show = action else {
            XCTFail("1 char に縮んでも .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(handler.candidateSession.isVisible, "BS で candidate が消えてはいけない")
    }

    func testBackspaceShrinkingToEmptyDismisses() {
        // 1 char → BS で空になったら .dismiss。これは現状維持。
        typeRomaji("ka")  // composedHiragana="か"
        let (consumed, action) = press(keyCode: KeyCode.backspace)
        XCTAssertTrue(consumed)
        if case .dismiss = action {} else { XCTFail(".dismiss を期待: \(action)") }
        XCTAssertEqual(handler.state.composedHiragana, "")
    }

    func testBackspaceOnEmptyCompositionDoesNotConsume() {
        let (consumed, action) = press(keyCode: KeyCode.backspace)
        XCTAssertFalse(consumed, "組成空での BS は consumed=false（アプリへ素通し）")
        if case .none = action {} else { XCTFail(".none を期待: \(action)") }
    }
}
