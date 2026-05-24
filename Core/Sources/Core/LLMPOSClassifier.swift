import Foundation
import FoundationModels
import OSLog

private let logger = Logger(subsystem: "com.leaner.keynaco", category: "POSClassifier")

/// 確定語の品詞をオンデバイス LLM で分類する。
/// Apple Intelligence が利用できない環境では何もしない（pos = NULL のまま → 全件表示）。
@MainActor
public final class LLMPOSClassifier {
    private struct POSJob {
        let output: String
        let context: String?
        let completion: @MainActor (_ output: String, _ pos: String, _ posTag: String, _ posRetry: Bool) -> Void
    }

    private var runningOutputs: Set<String> = []
    private var jobQueue: [POSJob] = []
    private var isProcessingQueue = false

    public init() {}

    /// 確定順 FIFO で 1 件ずつ分類する。noun_bigram 記録の順序保証用。
    public func enqueue(
        output: String,
        context: String? = nil,
        completion: @escaping @MainActor (_ output: String, _ pos: String, _ posTag: String, _ posRetry: Bool) -> Void
    ) {
        let effectiveContext = Self.shouldOmitClassificationContext(output) ? nil : context
        jobQueue.append(POSJob(output: output, context: effectiveContext, completion: completion))
        drainQueue()
    }

    /// `output` の品詞を非同期に判定し、結果を `completion` に返す。
    /// `context` は直前の確定済みテキスト（文脈）。渡すと固有名詞の subcategory 精度が上がる。
    /// 同じ output が並行して複数回呼ばれた場合は重複実行しない。バックフィル・デバッグ用。
    public func classify(
        output: String,
        context: String? = nil,
        completion: @escaping @MainActor (_ output: String, _ pos: String, _ posTag: String, _ posRetry: Bool) -> Void
    ) {
        runClassification(output: output, context: context, completion: completion)
    }

    private func drainQueue() {
        guard !isProcessingQueue, !jobQueue.isEmpty else { return }
        isProcessingQueue = true
        let job = jobQueue.removeFirst()
        let started = runClassification(output: job.output, context: job.context) { [weak self] output, pos, posTag, posRetry in
            job.completion(output, pos, posTag, posRetry)
            self?.isProcessingQueue = false
            self?.drainQueue()
        }
        if !started {
            isProcessingQueue = false
            drainQueue()
        }
    }

    @discardableResult
    private func runClassification(
        output: String,
        context: String? = nil,
        completion: @escaping @MainActor (_ output: String, _ pos: String, _ posTag: String, _ posRetry: Bool) -> Void
    ) -> Bool {
        guard case .available = SystemLanguageModel.default.availability else { return false }
        guard !runningOutputs.contains(output) else { return false }
        runningOutputs.insert(output)

        let session = LanguageModelSession(model: SystemLanguageModel.default) {
            """
            # Role
            Japanese POS Tagger for IME commit history.
            Reply: "tag:confidence" (high/mid/low).

            # Rules
            - Each token is an IME commit unit (surface form, no okurigana attached).
            - Classify by dictionary POS, not by possible sentence continuation.
            - サ変名詞 (実装, 入力, 確認, 設定, etc.) without する attached → noun.
            - Use preceding context only for proper_noun subcategory; do not flip noun/verb on standalone tokens.

            # Tagset
            - noun, verb, adjective, particle
            - proper_noun/[type]:
              - place (geo/facility), person (name)
              - org: Active entities that announce, hire, or decide. ("Apple が提訴した")
              - product: Consumable tools, devices, apps, or services. ("iPhone を買った")
              - work: Creative titles treated as atomic units. ("ドラゴンボールを読む")
            - other/conjunction, other/interjection, other/clause, other/unknown

            # Examples
            Apple → proper_noun/org:high
            iPhone → proper_noun/product:high
            Microsoft → proper_noun/org:high
            Windows 11 → proper_noun/product:high
            TypeScript → proper_noun/product:high
            東京 → proper_noun/place:high
            田中 → proper_noun/person:mid
            ドラゴンボール → proper_noun/work:high
            スラムダンク → proper_noun/work:high
            実装 → noun:high
            実装する → verb:high
            入力 → noun:high
            入力する → verb:high
            変換 → noun:high
            確認 → noun:high
            設定 → noun:high
            管理 → noun:high
            確認して → verb:high
            欲しい → adjective:high
            が → particle:high
            しかし → other/conjunction:high
            ええっと → other/interjection:high
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
                var pos = Self.categoryFromTag(posTag)
                var retry = Self.needsRetry(posTag: posTag)
                let adjusted = Self.applySuruNounHeuristic(output: output, pos: pos, posTag: posTag, posRetry: retry)
                pos = adjusted.pos
                retry = adjusted.posRetry
                if pos == "other" {
                    logger.warning("POS=other: output=\(output, privacy: .public) tag=\(posTag, privacy: .public)")
                }
                completion(output, pos, adjusted.posTag, retry)
            } catch {}
        }
        return true
    }

    /// 送り仮名なしの漢字 2〜4 字語幹（サ変名詞候補）。
    static nonisolated func isLikelySuruNounStem(_ output: String) -> Bool {
        guard output.count >= 2, output.count <= 4 else { return false }
        for scalar in output.unicodeScalars {
            guard scalar.properties.isIdeographic else { return false }
        }
        return true
    }

    /// 前文脈を渡すと verb に倒されやすいサ変名詞。context 省略判定用。
    static nonisolated func shouldOmitClassificationContext(_ output: String) -> Bool {
        suruNounContextOmitWords.contains(output)
    }

    private static nonisolated let suruNounContextOmitWords: Set<String> = [
        "実装", "入力", "変換", "確認", "設定", "管理", "作成", "削除", "更新", "追加",
        "実行", "保存", "検索", "表示", "登録", "修正", "反映", "取得", "送信", "受信",
    ]

    /// LLM が verb と返したサ変名詞語幹を noun に昇格する。
    static nonisolated func applySuruNounHeuristic(
        output: String,
        pos: String,
        posTag: String,
        posRetry: Bool
    ) -> (pos: String, posTag: String, posRetry: Bool) {
        guard pos == "verb", isLikelySuruNounStem(output) else {
            return (pos, posTag, posRetry)
        }
        return ("noun", "noun:mid", false)
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
            "proper_noun/place", "proper_noun/person", "proper_noun/org",
            "proper_noun/product", "proper_noun/work", "proper_noun",
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
    /// proper_noun / other は subcategory まで保持して返す。
    /// subcategory のない proper_noun は "proper_noun" のまま。
    static nonisolated func categoryFromTag(_ tag: String) -> String {
        // :confidence を除く
        let tagOnly = tag.components(separatedBy: ":").first ?? tag
        let parts = tagOnly.components(separatedBy: "/")
        let category = parts.first ?? tagOnly
        switch category {
        case "proper_noun":
            let known = ["place", "person", "org", "product", "work"]
            if parts.count >= 2, known.contains(parts[1]) {
                return "proper_noun/" + parts[1]
            }
            return "proper_noun"
        case "other":
            let known = ["conjunction", "interjection", "clause", "unknown"]
            if parts.count >= 2, known.contains(parts[1]) {
                return "other/" + parts[1]
            }
            return "other"
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
