import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

final class VowelKeyRegressionTests: InputHandlerTestCase {
    func testConsonantKeyPreservesCandidateSession() {
        let stub = SnapStub(["漢字", "感じ"])
        setUpWithConverter(stub)
        handler.deferAzooKeyWhileTyping = true

        typeRomaji("ai")
        XCTAssertTrue(handler.candidateSession.isVisible)

        let (_, action) = type(chars: "s", base: "s")
        if case .dismiss = action {
            XCTFail("子音キーで .dismiss を返してはいけない: \(action)")
        }
        XCTAssertTrue(handler.candidateSession.isVisible)
        XCTAssertEqual(handler.state.composedHiragana, "あい")
        XCTAssertEqual(handler.state.pendingRomaji, "s")
    }
}
