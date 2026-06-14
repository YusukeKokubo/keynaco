import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

final class VowelKeyRegressionTests: InputHandlerTestCase {
    func testConsonantKeyDismissesWhileTypingCandidates() {
        let stub = SnapStub(["漢字", "感じ"])
        setUpWithConverter(stub)
        handler.deferAzooKeyWhileTyping = true

        typeRomaji("ai")
        XCTAssertTrue(handler.candidateSession.isVisible)

        let (_, action) = type(chars: "s", base: "s")
        guard case .dismiss = action else {
            XCTFail("子音キーは .dismiss を返すはず: \(action)"); return
        }
        XCTAssertFalse(handler.candidateSession.isVisible)
        XCTAssertEqual(handler.state.composedHiragana, "あい")
        XCTAssertEqual(handler.state.pendingRomaji, "s")
        XCTAssertEqual(client.markedText, "あいs")
    }
}
