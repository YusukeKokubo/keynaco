import XCTest
@testable import KeynacoCore

// pendingRomaji 先読み（buildPendingCandidateList）。docs/domain/glossary.md Successor 関連も参照。

final class InputHandlerPendingPreviewTests: InputHandlerTestCase {

    // MARK: - pendingRomaji 先読み予測
    // 注: ひらがな末尾の単語を確定後（bi-gram なし → isSuccessorMode=false）に bi-gram を事後記録する
    // ことで、確定時には Successor モードに入らず、その後の先読みをテストできる

    func testPendingPreviewShowsCandidatesOnFirstChar() {
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        XCTAssertFalse(handler.isSuccessorMode)
        let (_, action) = type(chars: "k", base: "k")
        XCTAssertTrue(handler.isSuccessorMode, "先読み候補ありで isSuccessorMode になるはず")
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("bi-gram 学習済みで k → .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("から"), "学習済みの「から」が候補に含まれるはず")
    }

    func testPendingPreviewNExcluded() {
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        let (_, action) = type(chars: "n", base: "n")
        guard case .dismiss = action else {
            XCTFail("n は先読み対象外なので .dismiss を返すはず: \(action)"); return
        }
        XCTAssertFalse(handler.isSuccessorMode, "n では isSuccessorMode に入らないはず")
        XCTAssertEqual(handler.state.pendingRomaji, "n", "pendingRomaji = 'n' のまま残るはず")
    }

    func testPendingPreviewNoBigramDismisses() {
        typeRomaji("te")
        press(keyCode: 36)
        let (_, action) = type(chars: "k", base: "k")
        guard case .dismiss = action else {
            XCTFail("bi-gram 未学習で k → .dismiss を返すはず: \(action)"); return
        }
        XCTAssertFalse(handler.isSuccessorMode, "候補ゼロなら isSuccessorMode に入らないはず")
        XCTAssertEqual(handler.state.pendingRomaji, "k", "pendingRomaji = 'k' のまま残るはず")
    }

    func testPendingPreviewElectronSafetySetMarkedText() {
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        type(chars: "k", base: "k")
        XCTAssertFalse(client.markedText.isEmpty, "Electron 対策: markedText が空でないはず")
    }

    func testPendingPreviewSpaceConfirms() {
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        type(chars: "k", base: "k")
        XCTAssertTrue(handler.isSuccessorMode)
        press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "から")
        XCTAssertFalse(handler.isSuccessorMode, "Space 確定後は isSuccessorMode が解除されるはず")
        XCTAssertEqual(client.inserted.last, "から", "「から」が確定されるはず")
    }

    func testPendingPreviewEscapeCancels() {
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        type(chars: "k", base: "k")
        XCTAssertTrue(handler.isSuccessorMode)
        press(keyCode: 53)
        XCTAssertFalse(handler.isSuccessorMode, "Escape で isSuccessorMode が解除されるはず")
    }

    func testPendingPreviewCancelledByNonMatchingKeyContinuesRomaji() {
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        type(chars: "k", base: "k")
        XCTAssertTrue(handler.isSuccessorMode)
        let (_, action) = type(chars: "u", base: "u")
        XCTAssertFalse(handler.isSuccessorMode, "u でキャンセル後は isSuccessorMode = false")
        XCTAssertEqual(client.markedText, "く", "先読みキャンセル後に k+u=く になるはず（pendingRomaji が保持される）")
    }

    func testPendingPreviewConfirmedClearsPendingRomaji() {
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        type(chars: "k", base: "k")
        press(keyCode: 49, candidateVisible: true, selectedRow: 0, selectedText: "から")
        XCTAssertFalse(handler.isSuccessorMode)
        type(chars: "t", base: "t")
        type(chars: "u", base: "u")
        XCTAssertEqual(client.markedText, "つ", "先読み確定後に t+u=つ として組成されるはず")
    }

    func testPendingPreviewEscapePreservesRomajiInMarkedText() {
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "から", output: "から")
        type(chars: "k", base: "k")
        press(keyCode: 53)
        XCTAssertEqual(client.markedText, "k", "Escape 後に pendingRomaji が markedText に残るはず")
        let (_, action) = type(chars: "a", base: "a")
        XCTAssertEqual(client.markedText, "か", "Escape 後に続けて a を入力すると k+a=か になるはず")
    }

    // MARK: - pendingRomaji 先読み予測（f/j/c キー）

    func testPendingPreviewWithFKeyMatches() {
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "ふう", output: "風")
        let (_, action) = type(chars: "f", base: "f")
        XCTAssertTrue(handler.isSuccessorMode, "f キーで先読み候補あれば isSuccessorMode になるはず")
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("f キー先読み → .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("風"), "「ふ」行の bigram 候補が含まれるはず")
    }

    func testPendingPreviewWithJKeyMatches() {
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "じゆう", output: "自由")
        let (_, action) = type(chars: "j", base: "j")
        XCTAssertTrue(handler.isSuccessorMode, "j キーで先読み候補あれば isSuccessorMode になるはず")
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("j キー先読み → .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("自由"), "「じ」行の bigram 候補が含まれるはず")
    }

    func testPendingPreviewWithCKeyMatchesKaAndChiRows() {
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "ちかく", output: "近く")
        handler.db.recordBigram(prev: "て", input: "かれ", output: "彼")
        let (_, action) = type(chars: "c", base: "c")
        XCTAssertTrue(handler.isSuccessorMode)
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("c キー先読み → .show を返すはず: \(action)"); return
        }
        XCTAssertTrue(candidates.contains("近く") || candidates.contains("彼"),
                      "「ち」または「か」行の bigram 候補が含まれるはず: \(candidates)")
    }

    func testPendingPreviewNExclusionContinuesAsNormalRomaji() {
        typeRomaji("te")
        press(keyCode: 36)
        handler.db.recordBigram(prev: "て", input: "にほんご", output: "日本語")
        type(chars: "n", base: "n")
        XCTAssertFalse(handler.isSuccessorMode, "n では先読みに入らないはず")
        XCTAssertEqual(handler.state.pendingRomaji, "n")
        type(chars: "i", base: "i")
        XCTAssertEqual(client.markedText, "に", "n+i → に として組成されるはず")
        XCTAssertTrue(handler.state.pendingRomaji.isEmpty)
    }

    func testPendingPreviewTrigramPrioritizedInPreview() {
        typeRomaji("kinou")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "昨日")
        press(keyCode: 53)
        typeRomaji("toukyou")
        press(keyCode: 36, candidateVisible: true, selectedRow: 0, selectedText: "東京")
        press(keyCode: 53)
        handler.db.recordBigram(prev: "東京", input: "とさん", output: "都産")
        handler.db.recordTrigram(prev2: "昨日", prev1: "東京", input: "いった", output: "行った")
        let (_, action) = type(chars: "i", base: "i")
        guard case .show(let candidates, _, _, _, _) = action else {
            XCTFail("先読みで .show を返すはず: \(action)"); return
        }
        let idxItta = candidates.firstIndex(of: "行った")
        let idxTosan = candidates.firstIndex(of: "都産")
        XCTAssertNotNil(idxItta, "tri-gram 候補「行った」が含まれるはず: \(candidates)")
        if let i = idxItta, let t = idxTosan {
            XCTAssertLessThan(i, t, "tri-gram 由来の候補が bigram のみの候補より上位に来るはず")
        }
    }
}
