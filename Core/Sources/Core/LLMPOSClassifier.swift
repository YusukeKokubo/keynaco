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
    /// `context` は直前の確定済みテキスト（文脈）。渡すと固有名詞の subcategory 精度が上がる。
    /// 同じ output が並行して複数回呼ばれた場合は重複実行しない。
    public func classify(output: String, context: String? = nil, completion: @escaping @MainActor (_ output: String, _ pos: String, _ posTag: String, _ posRetry: Bool) -> Void) {
        guard case .available = SystemLanguageModel.default.availability else { return }
        guard !runningOutputs.contains(output) else { return }
        runningOutputs.insert(output)

        let session = LanguageModelSession(model: SystemLanguageModel.default) {
            """
            You are a Japanese POS tagger. Reply with ONLY tag:confidence on a single line. No explanation.
            - tag: one of the tags listed below
            - confidence: high / mid / low

            Tags:
            noun/common, noun/suru, noun/number
            proper_noun/place, proper_noun/person, proper_noun/org
            verb/te, verb/ta, verb/dict
            adjective/i, adjective/na, adjective/adv
            particle/case, particle/topic, particle/aux
            other/conjunction, other/interjection, other/clause, other/unknown

            proper_noun = real-world named entity (city, person, org). Generic words are noun/*, not proper_noun.

            Examples (noun/common or noun/suru — NOT proper_noun):
            入力 → noun/suru:high
            設定 → noun/suru:high
            固有名詞 → noun/common:high
            地名 → noun/common:high
            実装 → noun/suru:high
            確認 → noun/suru:high

            Examples (proper_noun — actual named entities):
            東京 → proper_noun/place:high
            東京タワー → proper_noun/place:high
            田中 → proper_noun/person:mid
            田中さん → proper_noun/person:high
            Apple → proper_noun/org:high
            TypeScript → proper_noun/org:high

            Examples (verb/adjective/particle):
            確認して → verb/te:high
            見つかった → verb/ta:high
            欲しい → adjective/i:high
            必要な → adjective/na:mid
            早速 → adjective/adv:mid
            は → particle/topic:high
            が → particle/case:high
            """
        }

        let prompt: String
        if let ctx = context, !ctx.isEmpty {
            prompt = "前文脈:「\(ctx)」\n「\(output)」の品詞タグを答えてください。"
        } else {
            prompt = "「\(output)」の品詞タグを答えてください。"
        }

        Task { @MainActor [weak self, session] in
            defer { self?.runningOutputs.remove(output) }
            do {
                let response = try await session.respond(to: prompt)
                let posTag = Self.normalizeTag(response.content)
                let pos = Self.categoryFromTag(posTag)
                let retry = Self.needsRetry(posTag: posTag)
                if pos == "other" {
                    logger.warning("POS=other: output=\(output, privacy: .public) tag=\(posTag, privacy: .public)")
                }
                completion(output, pos, posTag, retry)
            } catch {}
        }
    }

    /// LLM 応答から `tag:confidence` 形式のタグ部分を正規化して返す。
    /// 説明文が混入していても known タグを含む部分を抽出する。
    static nonisolated func normalizeTag(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.filter { $0 != "*" && $0 != "`" }
        let text = String(cleaned)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // `tag:confidence` 形式から最初のトークンを抽出（スペース・改行・説明文が付いていても対応）
        let knownPrefixes = [
            "proper_noun/place", "proper_noun/person", "proper_noun/org", "proper_noun",
            "noun/common", "noun/suru", "noun/number", "noun",
            "verb/te", "verb/ta", "verb/dict", "verb",
            "adjective/i", "adjective/na", "adjective/adv", "adjective",
            "particle/case", "particle/topic", "particle/aux", "particle",
            "other/conjunction", "other/interjection", "other/clause", "other/unknown", "other",
        ]
        for prefix in knownPrefixes {
            if let range = text.range(of: prefix) {
                // タグの後に :confidence が続く場合はそのまま保持
                let afterTag = text[range.upperBound...]
                if afterTag.hasPrefix(":") {
                    let confidence = afterTag.dropFirst().prefix(while: { $0.isLetter })
                    return prefix + ":" + confidence
                }
                return prefix
            }
        }
        return text
    }

    /// `tag:confidence` または `tag` から pos 値を返す。
    /// proper_noun は subcategory（/place・/person・/org）まで保持して返す。
    /// subcategory のない proper_noun は "proper_noun" のまま。
    static nonisolated func categoryFromTag(_ tag: String) -> String {
        // :confidence を除く
        let tagOnly = tag.components(separatedBy: ":").first ?? tag
        let parts = tagOnly.components(separatedBy: "/")
        let category = parts.first ?? tagOnly
        switch category {
        case "proper_noun":
            // proper_noun/place, proper_noun/person, proper_noun/org はそのまま保持
            let known = ["place", "person", "org"]
            if parts.count >= 2, known.contains(parts[1]) {
                return "proper_noun/" + parts[1]
            }
            return "proper_noun"
        case "noun":                                 return "noun"
        case "verb":                                 return "verb"
        case "adjective":                            return "adjective"
        case _ where category.contains("固有名詞"):  return "proper_noun"
        case _ where category.contains("名詞"):      return "noun"
        case _ where category.contains("動詞"):      return "verb"
        case _ where category.contains("形容"):      return "adjective"
        default:                                     return "other"
        }
    }

    /// `tag:confidence` の confidence が high / mid のときは retry 不要、それ以外は retry を要求する。
    static nonisolated func needsRetry(posTag: String) -> Bool {
        guard let colon = posTag.lastIndex(of: ":") else { return true }
        let confidence = String(posTag[posTag.index(after: colon)...])
        return confidence != "high" && confidence != "mid"
    }

    /// 後方互換：文字列から pos を直接導出する（テスト・バックフィル用）。
    static nonisolated func parsePOSString(_ raw: String) -> String {
        categoryFromTag(normalizeTag(raw))
    }
}
