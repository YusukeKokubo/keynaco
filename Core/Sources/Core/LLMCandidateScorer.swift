import Foundation
import FoundationModels

/// 変換候補を直前文脈に照らしてオンデバイス LLM が「最も自然な」1 件を選ぶ。
@MainActor
public final class LLMCandidateScorer {

    public struct ScorerResult: Sendable {
        public let index: Int
        public let confidence: Confidence

        public enum Confidence: Sendable {
            case high
            case mid
            case low
        }
    }

    private var task: Task<Void, Never>?

    public init() {}

    public func cancel() {
        task?.cancel()
        task = nil
    }

    /// - Parameter candidates: プロンプトに並べる候補文字列（最大10件想定）。
    /// - Parameter examples: N-gram DB の bi-gram 上位を few-shot として注入（最大5件想定）。
    /// - Parameter onResult: 成功時のみ呼ぶ。**`confidence == .low` のときは呼ばない**。
    ///   `index` は `candidates` 配列の 0-based。呼び出し側は `pendingF1GlobalIndices` でグローバル行へ写像する。
    public func score(
        candidates: [String],
        context: String,
        reading: String,
        examples: [(prev: String, next: String)] = [],
        onResult: @escaping (ScorerResult) -> Void
    ) {
        guard case .available = SystemLanguageModel.default.availability else { return }
        guard !candidates.isEmpty else { return }
        cancel()
        let prompt = Self.buildPrompt(
            context: context,
            reading: reading,
            candidates: candidates,
            examples: examples
        )
        let n = candidates.count
        let session = LanguageModelSession(model: SystemLanguageModel.default) {
            "あなたは日本語入力メソッドの補助モジュールです。指示された形式だけを出力し、説明文は書かないでください。"
        }
        task = Task { @MainActor [session] in
            do {
                let response = try await session.respond(to: prompt)
                guard let parsed = Self.parseChosenIndexWithConfidence(from: response, maxCount: n) else { return }
                guard parsed.confidence != .low else { return }
                onResult(parsed)
            } catch {}
        }
    }

    internal static func buildPrompt(
        context: String,
        reading: String,
        candidates: [String],
        examples: [(prev: String, next: String)]
    ) -> String {
        var lines = ""
        if !examples.isEmpty {
            lines += "【このユーザーの変換傾向】\n"
            for (prev, next) in examples {
                lines += "- 「\(prev)」の後 → 「\(next)」\n"
            }
            lines += "\n"
        }
        lines += """
        【文脈】\(context)
        【読み】\(reading)
        【候補】

        """
        for (i, c) in candidates.enumerated() {
            lines += "\(i + 1). \(c)\n"
        }
        lines += """

        最も自然な候補の番号と確信度を「番号:high」「番号:mid」「番号:low」の形式で1つだけ答えてください。
        例: 2:high
        """
        return lines
    }

    internal static func parseChosenIndexWithConfidence<Content>(
        from response: LanguageModelSession.Response<Content>,
        maxCount: Int
    ) -> ScorerResult? {
        guard let text = response.content as? String else { return nil }
        return parseChosenIndexWithConfidence(from: text, maxCount: maxCount)
    }

    /// LLM 応答文字列から 0-based インデックスと確信度を取り出す。
    internal static func parseChosenIndexWithConfidence(from text: String, maxCount: Int) -> ScorerResult? {
        guard maxCount >= 1 else { return nil }
        var i = text.startIndex
        while i < text.endIndex, !text[i].isWholeNumber {
            i = text.index(after: i)
        }
        guard i < text.endIndex else { return nil }
        var j = i
        while j < text.endIndex, text[j].isWholeNumber {
            j = text.index(after: j)
        }
        guard let oneBased = Int(String(text[i..<j])), oneBased >= 1, oneBased <= maxCount else { return nil }
        var k = j
        while k < text.endIndex, text[k].isWhitespace {
            k = text.index(after: k)
        }
        guard k < text.endIndex, text[k] == ":" else { return nil }
        k = text.index(after: k)
        while k < text.endIndex, text[k].isWhitespace {
            k = text.index(after: k)
        }
        guard k < text.endIndex else { return nil }
        let tail = text[k...].lowercased()
        let confidence: ScorerResult.Confidence
        if tail.hasPrefix("high") {
            confidence = .high
        } else if tail.hasPrefix("mid") {
            confidence = .mid
        } else if tail.hasPrefix("low") {
            confidence = .low
        } else {
            return nil
        }
        return ScorerResult(index: oneBased - 1, confidence: confidence)
    }
}
