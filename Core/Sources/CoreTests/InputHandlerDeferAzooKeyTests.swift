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

    /// Phase 3: 非同期経路は `richCandidates: true`（Space 先読みと同一キー）。
    func testDefer_immediateFixedHiraganaWhileAzooKeyPending() {
        typeRomaji("kanzi")
        let (action, pending) = handler.buildCandidateListWithoutAzooKey(trigger: .whileTyping)
        XCTAssertEqual(pending, "かんじ")
        guard case .show(let show) = action else {
            return XCTFail("expected show while AzooKey pending, got \(action)")
        }
        XCTAssertTrue(show.candidates.contains("かんじ"))
        XCTAssertTrue(show.candidates.contains("カンジ"))
    }

    func testDefer_injectPathMatchesSyncWhileTyping_withRichPrefetch() {
        let stub = RichCapturingStub(lines: ["漢字", "感じ"])
        setUpWithConverter(stub)
        handler.deferAzooKeyWhileTyping = true
        typeRomaji("ai")
        assertInjectPathMatchesSyncRich(stub: stub, trigger: .whileTyping)
        XCTAssertEqual(stub.lastRichCandidates, true)
    }

    /// 打鍵中のかなプレースホルダ表示中に Space を押したら明示変換（辞書取得）へ昇格する。
    func testDefer_spaceOnKanaPlaceholderUpgradesToExplicit() {
        let stub = SnapStub(["低頻度", "定頻度"])
        setUpWithConverter(stub)
        handler.deferAzooKeyWhileTyping = true
        typeRomaji("teihindo")
        applyCandidateAction(handler.buildCandidateListWithoutAzooKey(trigger: .whileTyping).action)
        XCTAssertEqual(handler.candidateSession.candidates, ["ていひんど", "テイヒンド"])
        let ctx = handler.candidateSession.makeContext()
        let (_, action) = handleAndApply(
            keyCode: KeyCode.space, characters: " ", baseCharacters: " ", candidate: ctx
        )
        guard case .show(let show) = action else {
            return XCTFail("expected .show from explicit upgrade, got \(action)")
        }
        XCTAssertTrue(show.candidates.contains("低頻度"),
                      "Space on kana placeholder should fetch dictionary: \(show.candidates)")
        XCTAssertTrue(show.initialIsExplicitlySelected)
    }
}

extension InputHandlerTestCase {
    /// 非同期 AzooKey（rich=true 先読み）と同期 `.whileTyping` の最終リスト一致。
    func assertInjectPathMatchesSyncRich(
        stub: any AzooKeyConverting,
        trigger: CandidateListTrigger = .explicit,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sync = handler.buildCandidateList(trigger: trigger)
        let (_, pending) = handler.buildCandidateListWithoutAzooKey(trigger: trigger)
        guard let reading = pending else {
            XCTFail("expected pending reading", file: file, line: line)
            return
        }
        let azooKey = stub.requestCandidates(
            hiragana: reading,
            leftSideContext: handler.leftContext.azooKeyValue,
            richCandidates: true
        )
        let inject = handler.rebuildCandidateList(
            reading: reading,
            azooKeyCandidates: azooKey,
            trigger: trigger
        )
        assertCandidateActionEqual(sync, inject, file: file, line: line)
    }
}

private final class RichCapturingStub: BaseAzooKeyStub, @unchecked Sendable {
    let lines: [String]
    private(set) var lastRichCandidates: Bool?

    init(lines: [String]) {
        self.lines = lines
        super.init()
    }

    override func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        lastRichCandidates = richCandidates
        return lines
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
