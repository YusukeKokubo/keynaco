import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

final class InputHandlerNumberTests: XCTestCase {

    // MARK: - generateNumberCandidates 単体テスト

    func testFourDigits() {
        let result = InputHandler.generateNumberCandidates(for: "1234")
        XCTAssertEqual(result, ["１２３４", "1,234", "１，２３４"])
    }

    func testSevenDigits() {
        let result = InputHandler.generateNumberCandidates(for: "1234567")
        XCTAssertEqual(result, ["１２３４５６７", "1,234,567", "１，２３４，５６７"])
    }

    func testThreeDigits() {
        // 3桁以下は桁区切りが元の文字列と同じになるため除外され全角のみ
        let result = InputHandler.generateNumberCandidates(for: "123")
        XCTAssertEqual(result, ["１２３"])
    }

    func testSingleDigit() {
        let result = InputHandler.generateNumberCandidates(for: "5")
        XCTAssertEqual(result, ["５"])
    }

    func testLeadingZero() {
        // 先頭ゼロがあると Int 変換後に消えるため桁区切りは生成しない
        let result = InputHandler.generateNumberCandidates(for: "0123")
        XCTAssertEqual(result, ["０１２３"])
    }

    func testEmptyString() {
        XCTAssertTrue(InputHandler.generateNumberCandidates(for: "").isEmpty)
    }

    func testNonDigitInput() {
        XCTAssertTrue(InputHandler.generateNumberCandidates(for: "abc").isEmpty)
    }

    func testMixedInput() {
        XCTAssertTrue(InputHandler.generateNumberCandidates(for: "12ab").isEmpty)
    }

    func testHiraganaInput() {
        XCTAssertTrue(InputHandler.generateNumberCandidates(for: "いち").isEmpty)
    }

    // MARK: - buildCandidateList 統合テスト

    func testNumberInputShowsCandidates() {
        let handler = InputHandler(db: DatabaseManager(inMemory: true))
        let client = MockTextClient()
        var h = handler

        for c in "1234" {
            _ = h.handle(keyCode: 0, characters: String(c), baseCharacters: String(c),
                         modifiers: [], candidate: .hidden, client: client)
        }
        let action = h.buildCandidateList(trigger: .whileTyping)
        guard let payload = action.showPayload else {
            XCTFail("Expected .show for digit input")
            return
        }
        XCTAssertTrue(payload.candidates.contains("１２３４"), "全角候補が含まれるはず: \(payload.candidates)")
        XCTAssertTrue(payload.candidates.contains("1,234"), "桁区切り候補が含まれるはず: \(payload.candidates)")
        XCTAssertTrue(payload.candidates.contains("１，２３４"), "全角桁区切り候補が含まれるはず: \(payload.candidates)")
    }

    func testNumberCandidatesNotRecordedInHistory() {
        var handler = InputHandler(db: DatabaseManager(inMemory: true))
        let client = MockTextClient()

        for c in "1234" {
            _ = handler.handle(keyCode: 0, characters: String(c), baseCharacters: String(c),
                               modifiers: [], candidate: .hidden, client: client)
        }
        // "１２３４" を選択確定
        let ctx = CandidateContext(isVisible: true, selectedRow: 2, selectedText: "１２３４")
        _ = handler.handle(keyCode: KeyCode.enter, characters: nil, baseCharacters: nil,
                           modifiers: [], candidate: ctx, client: client)
        XCTAssertEqual(client.inserted.last, "１２３４")

        // 再度 "1234" を入力して候補を確認 → 履歴に "１２３４" が出ないこと
        var handler2 = InputHandler(db: handler.db)
        let client2 = MockTextClient()
        for c in "1234" {
            _ = handler2.handle(keyCode: 0, characters: String(c), baseCharacters: String(c),
                                modifiers: [], candidate: .hidden, client: client2)
        }
        let action = handler2.buildCandidateList(trigger: .whileTyping)
        guard let payload = action.showPayload else {
            XCTFail("Expected .show"); return
        }
        // 履歴セクション（fixedEnd..<historyEnd）に "１２３４" が含まれないこと
        let historySection = Array(payload.candidates[payload.fixedEnd..<payload.historyEnd])
        XCTAssertFalse(historySection.contains("１２３４"), "全角候補は履歴に記録されてはいけない: \(historySection)")
    }
}
