import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

// PLAN260612 Phase 2: deferAzooKeyWhileTyping 経路の検証。

final class InputHandlerDeferAzooKeyTests: InputHandlerTestCase {
    private var mock: CountingAzooKeyStub!

    override func setUp() {
        super.setUp()
        mock = CountingAzooKeyStub(lines: ["漢字", "感じ"])
        setUpWithConverter(mock)
        handler.deferAzooKeyWhileTyping = true
    }

    func testDefer_handleDoesNotCallAzooKeySynchronously() {
        typeRomaji("ai")
        XCTAssertEqual(mock.requestCount, 0)
        XCTAssertEqual(handler.pendingAzooKeyReading, "あい")
    }

    func testDefer_pendingReadingNilForAsciiWord() {
        type(chars: "X", base: "x", modifiers: .shift)
        XCTAssertEqual(mock.requestCount, 0)
        XCTAssertNil(handler.pendingAzooKeyReading)
    }

    func testDefer_injectPathMatchesSyncWhileTyping() {
        typeRomaji("ai")
        assertInjectPathMatchesSync(stub: mock, trigger: .whileTyping)
    }

    func testDefer_functionalWordDismissMatchesSync() {
        let stub = SnapStub(["辞書A", "辞書B"])
        setUpWithConverter(stub)
        handler.deferAzooKeyWhileTyping = true
        typeRomaji("no")
        assertInjectPathMatchesSync(stub: stub, trigger: .whileTyping)
    }
}

private final class CountingAzooKeyStub: BaseAzooKeyStub, @unchecked Sendable {
    let lines: [String]
    private(set) var requestCount = 0

    init(lines: [String]) {
        self.lines = lines
        super.init()
    }

    override func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        requestCount += 1
        return lines
    }
}
