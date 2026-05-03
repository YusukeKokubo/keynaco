import Foundation
import FoundationModels

/// セグメントモード用：`composedHiragana` 全体をオンデバイス LLM で一括変換する。
@MainActor
final class LLMSegmentConverter {
    private var task: Task<Void, Never>?
    private lazy var session: LanguageModelSession = LanguageModelSession(model: SystemLanguageModel.default) {
        """
        あなたは日本語入力メソッドの補助モジュールです。指示された形式だけを出力し、説明文は書かないでください。
        """
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// 変換結果のテキストのみ（失敗時は空文字）。
    func convert(hiragana: String, onResult: @escaping (String) -> Void) {
        guard case .available = SystemLanguageModel.default.availability else {
            onResult("")
            return
        }
        cancel()
        let prompt = Self.buildPrompt(hiragana: hiragana)
        task = Task { @MainActor [session] in
            do {
                let response = try await session.respond(to: prompt)
                let text = Self.parseText(from: response)
                onResult(text)
            } catch {
                onResult("")
            }
        }
    }

    private static func buildPrompt(hiragana: String) -> String {
        """
        次のひらがなを自然な日本語に変換してください。変換結果のテキストだけを出力してください。
        \(hiragana)
        """
    }

    private static func parseText<Content>(from response: LanguageModelSession.Response<Content>) -> String {
        if let s = response.content as? String {
            return s
        }
        return ""
    }
}
