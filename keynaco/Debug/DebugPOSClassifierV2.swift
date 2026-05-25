#if DEBUG

import Foundation
import FoundationModels
import KeynacoCore
import OSLog

private let logger = Logger(subsystem: "com.leaner.keynaco", category: "POSClassifierV2")

// MARK: - @Generable 型（アプリターゲットで定義。SPM XPC 問題回避）

/// 最小 smoke test 用（フィールド1つ・制約なし）
@Generable
struct SmokeTestResult {
    @Guide(description: "answer")
    var answer: String
}

/// LLM 生成用構造体。String + .anyOf でトークンを制限する。
@Generable
struct POSResultV2 {
    @Guide(description: "POS label", .anyOf([
        "noun", "properNounPlace", "properNounPerson", "properNounOrg",
        "properNounProduct", "properNounWork", "verb", "adjective",
        "particle", "otherConjunction", "otherInterjection", "other"
    ]))
    var pos: String

    @Guide(description: "Confidence", .anyOf(["high", "mid", "low"]))
    var confidence: String

    var label: POSLabelV2 {
        POSLabelV2(rawValue: pos) ?? .other
    }
}

// MARK: - Tool Calling アプローチ（respond(to:generating:) ハング回避 POC）

actor POSResultCapture {
    var result: (pos: String, confidence: String)?
    func store(pos: String, confidence: String) {
        result = (pos: pos, confidence: confidence)
    }
}

@Generable
struct POSToolParameters {
    @Guide(description: "Part of speech label for the input word", .anyOf([
        "noun", "properNounPlace", "properNounPerson", "properNounOrg",
        "properNounProduct", "properNounWork", "verb", "adjective",
        "particle", "otherConjunction", "otherInterjection", "other"
    ]))
    var pos: String

    @Guide(description: "Classification confidence", .anyOf(["high", "mid", "low"]))
    var confidence: String
}

struct POSTagTool: Tool {
    let capture: POSResultCapture

    var name: String { "submit_pos_tag" }
    var description: String {
        "Submit POS classification result. You MUST call this tool with your answer."
    }

    typealias Arguments = POSToolParameters

    func call(arguments: POSToolParameters) async throws -> String {
        await capture.store(pos: arguments.pos, confidence: arguments.confidence)
        return "ok"
    }
}

// MARK: - POC 分類器

@MainActor
final class DebugPOSClassifierV2 {

    func classify(output: String, context: String? = nil) async -> (POSResultV2?, String?) {
        guard case .available = SystemLanguageModel.default.availability else {
            return (nil, "unavailable")
        }
        // 修正1: instructions: ラベルで正しく初期化
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: """
            You are a Japanese POS tagger for IME commit history.
            Rules:
            - Suru-verb noun stems (設定, 実装, 確認, 追加, 申請, etc.) without する -> noun.
            - Phrases with a case particle suffix (課題を, 価値が, etc.) -> particle.
            - Use context only to determine proper_noun subcategory.
            Examples: 設定->noun,high / チーム->noun,high / 確認して->verb,high / が->particle,high / しかし->otherConjunction,high
            """
        )
        let prompt = context.map { "Context: \"\($0)\"\nClassify: \"\(output)\"" }
                  ?? "Classify: \"\(output)\""
        let start = Date()
        do {
            // 修正2: 正しいシグネチャ（generating: が第1引数、prompt は末尾クロージャ）
            let response = try await session.respond(generating: POSResultV2.self) {
                Prompt(prompt)
            }
            let elapsed = Date().timeIntervalSince(start)
            logger.info("V2: \(output, privacy: .public) → \(response.content.pos, privacy: .public):\(response.content.confidence, privacy: .public) (\(String(format: "%.2f", elapsed))s)")
            return (response.content, nil)
        } catch {
            let msg = String(describing: error)
            logger.error("V2 failed: \(output, privacy: .public) \(msg, privacy: .public)")
            return (nil, msg)
        }
    }

    func smokeTest() async -> (String?, String?) {
        guard case .available = SystemLanguageModel.default.availability else {
            return (nil, "unavailable")
        }
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: "Answer with a single word."
        )
        let start = Date()
        do {
            let response = try await session.respond(generating: SmokeTestResult.self) {
                Prompt("Reply with the word 'ok'.")
            }
            let elapsed = Date().timeIntervalSince(start)
            logger.info("smoke ok: \(response.content.answer, privacy: .public) (\(String(format: "%.2f", elapsed))s)")
            return (response.content.answer, nil)
        } catch {
            return (nil, String(describing: error))
        }
    }

    func runValidation() async -> [POCValidationResult] {
        var results: [POCValidationResult] = []
        for c in POCValidationCase.validationSet {
            let start = Date()
            let (result, errMsg) = await classify(output: c.output)
            let elapsed = Date().timeIntervalSince(start)
            let actualLabel = result?.label
            results.append(POCValidationResult(
                output: c.output,
                expected: c.expectedPos,
                actual: actualLabel,
                confidence: result?.confidence ?? "-",
                pass: actualLabel == c.expectedPos,
                elapsedSeconds: elapsed,
                errorMessage: errMsg
            ))
        }
        return results
    }

    // MARK: - Tool Calling variant

    func classifyViaToolCalling(output: String, context: String? = nil) async -> (pos: String, confidence: String, error: String?) {
        guard case .available = SystemLanguageModel.default.availability else {
            return ("other", "low", "unavailable")
        }
        let capture = POSResultCapture()
        let tool = POSTagTool(capture: capture)
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            tools: [tool],
            instructions: """
            You are a Japanese POS tagger for IME commit history.
            Rules:
            - Suru-verb noun stems (設定, 実装, 確認, 追加, 申請, etc.) without する -> noun.
            - Phrases with a case particle suffix (課題を, 価値が, etc.) -> particle.
            Examples: 設定->noun,high / チーム->noun,high / 確認して->verb,high / しかし->otherConjunction,high
            Always call submit_pos_tag with your answer.
            """
        )
        let prompt = context.map { "Context: \"\($0)\"\nClassify: \"\(output)\"" }
                  ?? "Classify: \"\(output)\""
        let start = Date()
        do {
            _ = try await session.respond(to: prompt)
        } catch {
            let msg = String(describing: error)
            logger.error("TC failed: \(output, privacy: .public) \(msg, privacy: .public)")
            return ("other", "low", msg)
        }
        let elapsed = Date().timeIntervalSince(start)
        if let result = await capture.result {
            logger.info("TC: \(output, privacy: .public) → \(result.pos, privacy: .public):\(result.confidence, privacy: .public) (\(String(format: "%.2f", elapsed))s)")
            return (result.pos, result.confidence, nil)
        }
        logger.warning("TC: tool not called for \(output, privacy: .public)")
        return ("other", "low", "tool_not_called")
    }

    func runToolCallingValidation() async -> [POCValidationResult] {
        var results: [POCValidationResult] = []
        for c in POCValidationCase.validationSet {
            let start = Date()
            let (pos, confidence, errMsg) = await classifyViaToolCalling(output: c.output)
            let elapsed = Date().timeIntervalSince(start)
            let actualLabel = POSLabelV2(rawValue: pos)
            results.append(POCValidationResult(
                output: c.output,
                expected: c.expectedPos,
                actual: actualLabel,
                confidence: confidence,
                pass: actualLabel == c.expectedPos,
                elapsedSeconds: elapsed,
                errorMessage: errMsg
            ))
        }
        return results
    }
}

#endif
