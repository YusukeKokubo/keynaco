import XCTest
@testable import KeynacoCore
@testable import KeynacoTestSupport

final class InputHandlerNumericReadingTests: XCTestCase {

    private final class RecordingAzooKeyStub: BaseAzooKeyStub {
        private(set) var lastHiragana: String?

        override func requestCandidates(
            hiragana: String,
            leftSideContext: String?,
            richCandidates: Bool,
            options: AzooKeyFetchOptions
        ) -> [AzooKeyCandidate] {
            lastHiragana = hiragana
            return []
        }
    }

    func test7GatuTypingPassesExpandedReadingToAzooKey() {
        let stub = RecordingAzooKeyStub()
        var handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: stub)
        let client = MockTextClient()

        for c in "7gatu" {
            let r = handler.handle(
                keyCode: 0,
                characters: String(c),
                baseCharacters: String(c),
                modifiers: [],
                candidate: .hidden,
                client: client
            )
            if r.consumed {
                handler.applyCandidateAction(r.candidateAction, client: client)
            }
        }
        XCTAssertEqual(handler.state.composedHiragana, "7がつ")
        _ = handler.buildCandidateList(trigger: .explicit)
        XCTAssertEqual(stub.lastHiragana, "しちがつ")
    }

    func testUserReadingUnchangedForHistoryKey() {
        var handler = InputHandler(db: DatabaseManager(inMemory: true))
        let client = MockTextClient()

        for c in "7gatu" {
            _ = handler.handle(
                keyCode: 0,
                characters: String(c),
                baseCharacters: String(c),
                modifiers: [],
                candidate: .hidden,
                client: client
            )
        }
        XCTAssertEqual(InputHandler.azooKeyReading(for: handler.state.composedHiragana), "しちがつ")
        XCTAssertEqual(handler.state.composedHiragana, "7がつ")
    }
}
