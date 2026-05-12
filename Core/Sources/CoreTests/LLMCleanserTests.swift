import XCTest
@testable import KeynacoCore

/// `LLMCleanser` の FoundationModels 可用性分岐と空 DB の短絡パスを検証する。
/// Apple Intelligence が有効な環境では空結果の非 LLM パスも通る。
final class LLMCleanserTests: XCTestCase {

    func testEvaluateThrowsUnavailableWhenModelUnavailable() async throws {
        guard !LLMCleanser.isModelAvailable else {
            throw XCTSkip("オンデバイス言語モデルが利用可能なため unavailable パスをスキップ")
        }
        let db = DatabaseManager(inMemory: true)
        let cleanser = LLMCleanser()
        do {
            _ = try await cleanser.evaluate(db: db)
            XCTFail("unavailable 時は CleanserError.unavailable を投げるべき")
        } catch CleanserError.unavailable {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEvaluateEmptyDatabaseReturnsEmptyWhenModelAvailable() async throws {
        guard LLMCleanser.isModelAvailable else {
            throw XCTSkip("FoundationModels が利用不可のため空 DB の短絡パスをスキップ")
        }
        let db = DatabaseManager(inMemory: true)
        let cleanser = LLMCleanser()
        var progressCalls: [(Int, Int)] = []
        let rows = try await cleanser.evaluate(db: db) { completed, total in
            progressCalls.append((completed, total))
        }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(progressCalls.count, 1)
        XCTAssertEqual(progressCalls[0].0, 0)
        XCTAssertEqual(progressCalls[0].1, 0)
    }
}
