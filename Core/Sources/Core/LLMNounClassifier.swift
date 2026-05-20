import Foundation
import FoundationModels

/// 確定語が名詞（体言）かどうかをオンデバイス LLM で分類する。
/// Apple Intelligence が利用できない環境では何もしない（is_noun = NULL のまま → 全件表示）。
@MainActor
public final class LLMNounClassifier {
    private var runningOutputs: Set<String> = []

    public init() {}

    /// `output` の品詞を非同期に判定し、結果を `completion` に返す。
    /// 同じ output が並行して複数回呼ばれた場合は重複実行しない。
    public func classify(output: String, completion: @escaping @MainActor (String, Bool) -> Void) {
        guard case .available = SystemLanguageModel.default.availability else { return }
        guard !runningOutputs.contains(output) else { return }
        runningOutputs.insert(output)

        let session = LanguageModelSession(model: SystemLanguageModel.default) {
            """
            日本語の語や句が名詞（体言）かどうかを判定します。
            名詞・固有名詞・サ変名詞・数詞であれば「はい」、
            動詞・形容詞・副詞・助詞・接続詞・文節であれば「いいえ」とだけ答えてください。
            """
        }

        Task { @MainActor [weak self, session] in
            defer { self?.runningOutputs.remove(output) }
            do {
                let response = try await session.respond(to: "「\(output)」は名詞（体言）ですか？")
                let isNoun = Self.parseIsNoun(from: response)
                completion(output, isNoun)
            } catch {}
        }
    }

    static func parseIsNoun(from response: LanguageModelSession.Response<String>) -> Bool {
        response.content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("はい")
    }
}
