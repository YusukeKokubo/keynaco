import Foundation
import FoundationModels

/// 確定語の品詞をオンデバイス LLM で分類する。
/// Apple Intelligence が利用できない環境では何もしない（pos = NULL のまま → 全件表示）。
@MainActor
public final class LLMPOSClassifier {
    private var runningOutputs: Set<String> = []

    public init() {}

    /// `output` の品詞を非同期に判定し、結果を `completion` に返す。
    /// 同じ output が並行して複数回呼ばれた場合は重複実行しない。
    public func classify(output: String, completion: @escaping @MainActor (String, String) -> Void) {
        guard case .available = SystemLanguageModel.default.availability else { return }
        guard !runningOutputs.contains(output) else { return }
        runningOutputs.insert(output)

        let session = LanguageModelSession(model: SystemLanguageModel.default) {
            """
            日本語の語や句の品詞を以下の4種類のうち1つだけ答えてください。
            - noun: 名詞・固有名詞・サ変名詞・数詞
            - verb: 動詞
            - adjective: 形容詞・形容動詞・副詞
            - other: 助詞・助動詞・接続詞・感動詞・文節
            1単語のみ回答してください。
            """
        }

        Task { @MainActor [weak self, session] in
            defer { self?.runningOutputs.remove(output) }
            do {
                let response = try await session.respond(to: "「\(output)」の品詞を答えてください。")
                let pos = Self.parsePOS(from: response)
                completion(output, pos)
            } catch {}
        }
    }

    static func parsePOS(from response: LanguageModelSession.Response<String>) -> String {
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("noun") { return "noun" }
        if text.hasPrefix("verb") { return "verb" }
        if text.hasPrefix("adjective") { return "adjective" }
        return "other"
    }
}
