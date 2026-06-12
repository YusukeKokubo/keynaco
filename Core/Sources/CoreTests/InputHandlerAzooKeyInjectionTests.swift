import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

// PLAN260612 Phase 1: AzooKey 注入経路のガード・即時経路検証。
// リスト構造の inject 等価性は InputHandlerCandidateSnapshotTests が担う。

final class InputHandlerAzooKeyInjectionTests: InputHandlerTestCase {
    private var stub: SnapStub!

    private func useStub(_ stub: SnapStub) {
        self.stub = stub
        setUpWithConverter(stub)
    }

    // MARK: - pendingReading

    func testWithoutAzooKey_pendingReading() {
        useStub(SnapStub([]))
        typeRomaji("ai")
        let (_, pending) = handler.buildCandidateListWithoutAzooKey(trigger: .whileTyping)
        XCTAssertEqual(pending, "あい")

        setUpWithConverter(SnapStub([]))
        let (consumed, _) = type(chars: "X", base: "x", modifiers: .shift)
        XCTAssertTrue(consumed)
        let (_, asciiPending) = handler.buildCandidateListWithoutAzooKey(trigger: .whileTyping)
        XCTAssertNil(asciiPending)
    }

    // MARK: - stale ガード

    func testRebuild_staleReadingReturnsNone() {
        useStub(SnapStub(["辞書A", "辞書B"]))
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
        useStub(SnapStub(["辞書A", "辞書B"]))
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
        useStub(SnapStub(["辞書A", "辞書B"]))
        typeRomaji("no")
        let sync = handler.buildCandidateList(trigger: .whileTyping)
        assertDismiss(sync)
        assertInjectPathMatchesSync(stub: stub, trigger: .whileTyping)
    }
}
