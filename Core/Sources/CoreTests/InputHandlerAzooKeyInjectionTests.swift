import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

// PLAN260612 Phase 1: AzooKey 注入経路の等価性・ガード検証。

private final class InjectionSnapStub: BaseAzooKeyStub, @unchecked Sendable {
    let lines: [String]
    init(_ lines: [String], zenzai: Bool = false) {
        self.lines = lines
        super.init()
        isZenzaiEnabled = zenzai
    }
    override func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String] {
        lines
    }
}

final class InputHandlerAzooKeyInjectionTests: InputHandlerTestCase {
    private var stub: InjectionSnapStub!

    private func useStub(_ stub: InjectionSnapStub) {
        self.stub = stub
        setUpWithConverter(stub)
    }

    private func assertShowPayloadEqual(
        _ lhs: CandidateAction,
        _ rhs: CandidateAction,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard let l = lhs.showPayload, let r = rhs.showPayload else {
            XCTFail("Expected both .show but got \(lhs) vs \(rhs)", file: file, line: line)
            return
        }
        XCTAssertEqual(l.candidates, r.candidates, "candidates", file: file, line: line)
        XCTAssertEqual(l.historyEnd, r.historyEnd, "historyEnd", file: file, line: line)
        XCTAssertEqual(l.fixedEnd, r.fixedEnd, "fixedEnd", file: file, line: line)
        XCTAssertEqual(l.initialRow, r.initialRow, "initialRow", file: file, line: line)
        XCTAssertEqual(l.zenzaiRow, r.zenzaiRow, "zenzaiRow", file: file, line: line)
        XCTAssertEqual(
            l.initialIsExplicitlySelected,
            r.initialIsExplicitlySelected,
            "initialIsExplicitlySelected",
            file: file,
            line: line
        )
    }

    private func rebuilt(
        trigger: CandidateListTrigger,
        file: StaticString = #file,
        line: UInt = #line
    ) -> CandidateAction {
        let (_, pending) = handler.buildCandidateListWithoutAzooKey(trigger: trigger)
        guard let reading = pending else {
            XCTFail("Expected pendingReading", file: file, line: line)
            return .none
        }
        let azooKey = stub.requestCandidates(
            hiragana: reading,
            leftSideContext: handler.leftContext.azooKeyValue,
            richCandidates: trigger == .explicit
        )
        return handler.rebuildCandidateList(
            reading: reading,
            azooKeyCandidates: azooKey,
            trigger: trigger
        )
    }

    // MARK: - 等価性

    func testRebuildMatchesSync_explicit() {
        useStub(InjectionSnapStub(["辞書A", "辞書B"]))
        handler.db.record(input: "あい", output: "愛")
        typeRomaji("ai")
        let sync = handler.buildCandidateList(trigger: .explicit)
        assertShowPayloadEqual(sync, rebuilt(trigger: .explicit))
    }

    func testRebuildMatchesSync_whileTyping() {
        useStub(InjectionSnapStub(["辞書A", "辞書B"]))
        handler.db.record(input: "あい", output: "愛")
        typeRomaji("ai")
        let sync = handler.buildCandidateList(trigger: .whileTyping)
        assertShowPayloadEqual(sync, rebuilt(trigger: .whileTyping))
    }

    // MARK: - pendingReading

    func testWithoutAzooKey_pendingReading() {
        useStub(InjectionSnapStub([]))
        typeRomaji("ai")
        let (_, pending) = handler.buildCandidateListWithoutAzooKey(trigger: .whileTyping)
        XCTAssertEqual(pending, "あい")

        setUpWithConverter(InjectionSnapStub([]))
        let (consumed, _) = type(chars: "X", base: "x", modifiers: .shift)
        XCTAssertTrue(consumed)
        let (_, asciiPending) = handler.buildCandidateListWithoutAzooKey(trigger: .whileTyping)
        XCTAssertNil(asciiPending)
    }

    // MARK: - stale ガード

    func testRebuild_staleReadingReturnsNone() {
        useStub(InjectionSnapStub(["辞書A", "辞書B"]))
        typeRomaji("ai")
        let reading = handler.state.composedHiragana
        type(chars: "u", base: "u")
        let azooKey = stub.requestCandidates(
            hiragana: reading,
            leftSideContext: handler.leftContext.azooKeyValue,
            richCandidates: false
        )
        let action = handler.rebuildCandidateList(
            reading: reading,
            azooKeyCandidates: azooKey,
            trigger: .whileTyping
        )
        guard case .none = action else {
            XCTFail("読みが進んだあとの rebuild は .none を返すはず: \(action)")
            return
        }
    }

    // MARK: - whileTyping 即時 dismiss

    func testWithoutAzooKey_whileTypingDismissWhenOnlyAzooKey() {
        useStub(InjectionSnapStub(["辞書A", "辞書B"]))
        typeRomaji("ai")
        let (immediate, pending) = handler.buildCandidateListWithoutAzooKey(trigger: .whileTyping)
        guard case .dismiss = immediate else {
            XCTFail("安価ソースなしの whileTyping は即時 .dismiss を返すはず: \(immediate)")
            return
        }
        XCTAssertEqual(pending, "あい")
    }

    // MARK: - 機能語第一候補 dismiss

    func testRebuild_whileTypingFunctionalWordDismiss() {
        useStub(InjectionSnapStub(["辞書A", "辞書B"]))
        typeRomaji("no")
        let sync = handler.buildCandidateList(trigger: .whileTyping)
        assertDismiss(sync)
        assertDismiss(rebuilt(trigger: .whileTyping))
    }

    // MARK: - Zenzai プロモート

    func testRebuild_zenzaiPromote() {
        useStub(InjectionSnapStub(["Zen先頭", "辞書B"], zenzai: true))
        handler.leftContext = .testing(combined: "prefix")
        typeRomaji("ai")
        let sync = handler.buildCandidateList(trigger: .whileTyping)
        assertShowPayloadEqual(sync, rebuilt(trigger: .whileTyping))
    }
}
