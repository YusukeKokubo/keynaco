import Foundation
import FoundationModels
import OSLog

private let logger = Logger(subsystem: "com.leaner.keynaco", category: "POSClassifier")

/// 確定語の品詞をオンデバイス LLM で分類する。
/// Apple Intelligence が利用できない環境では何もしない（pos = NULL のまま → 全件表示）。
@MainActor
public final class LLMPOSClassifier {
    private var runningOutputs: Set<String> = []

    public init() {}

    /// `output` の品詞を非同期に判定し、結果を `completion` に返す。
    /// 同じ output が並行して複数回呼ばれた場合は重複実行しない。
    public func classify(output: String, completion: @escaping @MainActor (_ output: String, _ pos: String, _ rawResponse: String) -> Void) {
        guard case .available = SystemLanguageModel.default.availability else { return }
        guard !runningOutputs.contains(output) else { return }
        runningOutputs.insert(output)

        let session = LanguageModelSession(model: SystemLanguageModel.default) {
            """
            日本語の語や句の品詞を以下の5種類のうち1つだけ答えてください。
            - noun: 普通名詞・サ変名詞・数詞
            - proper_noun: 固有名詞（人名・地名・施設名・ブランド名など）
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
                let rawResponse = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let pos = Self.parsePOSString(rawResponse)
                if pos == "other" {
                    logger.warning("POS=other: output=\(output, privacy: .public) raw=\(rawResponse, privacy: .public)")
                }
                completion(output, pos, rawResponse)
            } catch {}
        }
    }

    static nonisolated func parsePOSString(_ raw: String) -> String {
        // LLM が **noun** や `verb`、_noun_ のように Markdown 装飾を付けることがあるため除去する
        // * と ` は語中に現れないので全削除、_ は語中の区切り文字になりうるので前後のみトリム
        let noAsterisks = raw.unicodeScalars.filter { $0 != "*" && $0 != "`" }
        let text = String(noAsterisks)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if text.hasPrefix("proper_noun") || text.contains("固有名詞") { return "proper_noun" }
        if text.hasPrefix("noun") || text.hasPrefix("名詞") { return "noun" }
        if text.hasPrefix("verb") || text.hasPrefix("動詞") { return "verb" }
        if text.hasPrefix("adjective") || text.hasPrefix("形容詞") || text.hasPrefix("副詞") { return "adjective" }
        return "other"
    }
}
