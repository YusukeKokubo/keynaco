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
        let completion: @MainActor (
            _ output: String,
            _ pos: String,
            _ posTag: String,
            _ posRetry: Bool,
            _ lemma: String?
        ) -> Void
    }

    private var runningOutputs: Set<String> = []
    private var jobQueue: [POSJob] = []
    private var isProcessingQueue = false

    public init() {}

    /// 確定順 FIFO で 1 件ずつ分類する（`schedulePOSClassification` から利用）。
    public func enqueue(
        output: String,
        context: String? = nil,
        completion: @escaping @MainActor (
            _ output: String,
            _ pos: String,
            _ posTag: String,
            _ posRetry: Bool,
            _ lemma: String?
        ) -> Void
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
        completion: @escaping @MainActor (
            _ output: String,
            _ pos: String,
            _ posTag: String,
            _ posRetry: Bool,
            _ lemma: String?
        ) -> Void
    ) {
        runClassification(output: output, context: context, completion: completion)
    }

    private func drainQueue() {
        guard !isProcessingQueue, !jobQueue.isEmpty else { return }
        isProcessingQueue = true
        let job = jobQueue.removeFirst()
        let started = runClassification(output: job.output, context: job.context) { [weak self] output, pos, posTag, posRetry, lemma in
            job.completion(output, pos, posTag, posRetry, lemma)
            self?.isProcessingQueue = false
            self?.drainQueue()
        }
        if !started {
            // 同一 output の classify が走行中なら job を捨てずに再試行する
            if case .available = SystemLanguageModel.default.availability,
               runningOutputs.contains(job.output) {
                jobQueue.insert(job, at: 0)
                isProcessingQueue = false
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    self?.drainQueue()
                }
                return
            }
            isProcessingQueue = false
            drainQueue()
            return
        }
    }

    @discardableResult
    private func runClassification(
        output: String,
        context: String? = nil,
        completion: @escaping @MainActor (
            _ output: String,
            _ pos: String,
            _ posTag: String,
            _ posRetry: Bool,
            _ lemma: String?
        ) -> Void
    ) -> Bool {
        guard case .available = SystemLanguageModel.default.availability else { return false }
        guard !runningOutputs.contains(output) else { return false }
        runningOutputs.insert(output)

        let session = LanguageModelSession(model: SystemLanguageModel.default) {
            """
            # Role
            Japanese POS Tagger for IME commit history.

            # Response format
            - Default: "tag:confidence" (high/mid/low)
            - Verb only: "tag:confidence:lemma" (dictionary form)

            # Rules
            - Each token is an IME commit unit (surface form, no okurigana attached).
            - Classify by dictionary POS, not by possible sentence continuation.
            - サ変名詞 (実装, 入力, 確認, 設定, etc.) without する attached → noun.
            - Use preceding context only for proper_noun subcategory; do not flip noun/verb on standalone tokens.
            - For verbs, always append dictionary form (lemma) as the third field.

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
            実装する → verb:high:実装する
            入力 → noun:high
            入力する → verb:high:入力する
            変換 → noun:high
            確認 → noun:high
            設定 → noun:high
            管理 → noun:high
            行った → verb:high:行く
            設定した → verb:high:設定する
            確認して → verb:high:確認する
            書きます → verb:high:書く
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
                let (posTag, lemma) = Self.parseTagAndLemma(response.content)
                var pos = Self.categoryFromTag(posTag)
                var retry = Self.needsRetry(posTag: posTag)
                let adjusted = Self.applySuruNounHeuristic(output: output, pos: pos, posTag: posTag, posRetry: retry)
                pos = adjusted.pos
                retry = adjusted.posRetry
                let effectiveLemma = pos == "verb" ? lemma : nil
                if pos == "other" {
                    logger.warning("POS=other: output=\(output, privacy: .public) tag=\(posTag, privacy: .public)")
                }
                completion(output, pos, adjusted.posTag, retry, effectiveLemma)
            } catch {
                logger.error("POS classify failed: output=\(output, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
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

    private static nonisolated let knownTagPrefixes = [
        "proper_noun/place", "proper_noun/person", "proper_noun/org",
        "proper_noun/product", "proper_noun/work", "proper_noun",
        "noun/common", "noun/suru", "noun/number", "noun",
        "verb/te", "verb/ta", "verb/dict", "verb",
        "adjective/i", "adjective/na", "adjective/adv", "adjective",
        "particle/case", "particle/topic", "particle/aux", "particle",
        "other/conjunction", "other/interjection", "other/clause", "other/unknown", "other",
    ]

    private static nonisolated func cleanedResponse(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.filter { $0 != "*" && $0 != "`" }
        return String(cleaned)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// LLM 応答から `tag:confidence` と動詞 lemma を抽出する。
    static nonisolated func parseTagAndLemma(_ raw: String) -> (posTag: String, lemma: String?) {
        let text = cleanedResponse(raw)
        for prefix in knownTagPrefixes {
            guard let range = text.range(of: prefix) else { continue }
            let afterTag = text[range.upperBound...]
            guard afterTag.hasPrefix(":") else { return (prefix, nil) }
            let rest = afterTag.dropFirst()
            let colonParts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let confidence = colonParts.first.map(String.init) ?? ""
            let posTag = confidence.isEmpty ? prefix : "\(prefix):\(confidence)"
            let lemma: String? = {
                guard categoryFromTag(posTag) == "verb", colonParts.count > 1 else { return nil }
                let value = String(colonParts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }()
            return (posTag, lemma)
        }
        return (text, nil)
    }

    /// LLM 応答から `tag:confidence` 形式のタグ部分を正規化して返す。
    /// 説明文が混入していても known タグを含む部分を抽出する。
    static nonisolated func normalizeTag(_ raw: String) -> String {
        parseTagAndLemma(raw).posTag
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
