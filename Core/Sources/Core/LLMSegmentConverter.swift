import Foundation
import FoundationModels

/// セグメントモード用：`composedHiragana` 全体をオンデバイス LLM で一括変換する。
@MainActor
public final class LLMSegmentConverter {
    private var task: Task<Void, Never>?

    public init() {}

    public func cancel() {
        task?.cancel()
        task = nil
    }

    /// 変換結果のテキストのみ（失敗時は空文字）。
    public func convert(hiragana: String, onResult: @escaping (String) -> Void) {
        guard case .available = SystemLanguageModel.default.availability else {
            onResult("")
            return
        }
        cancel()
        let prompt = Self.buildPrompt(hiragana: hiragana)
        let session = LanguageModelSession(model: SystemLanguageModel.default) {
            "あなたは日本語入力メソッドの補助モジュールです。指示された形式だけを出力し、説明文は書かないでください。"
        }
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

    /// LLM の変換全文とひらがな読みから文節境界 `(reading, token)` を推定する。失敗時は `nil`。
    nonisolated static func inferSegmentBoundaries(
        hiragana: String,
        llmText: String,
        azooKey: AzooKeyConverting,
        baselineSegmentReadings: [String],
        leftSideContext: String? = nil
    ) -> [(reading: String, token: String)]? {
        let processed = Self.preprocessLLMText(llmText)
        guard !processed.isEmpty, !hiragana.isEmpty else { return nil }
        guard baselineSegmentReadings.joined() == hiragana else { return nil }
        let tokens = Self.tokenizeByScript(processed)
        guard !tokens.isEmpty else { return nil }

        var remaining = hiragana
        var pairs: [(reading: String, token: String)] = []

        for token in tokens {
            guard !remaining.isEmpty else { return nil }

            func consumedPrefix() -> String {
                String(hiragana.prefix(hiragana.count - remaining.count))
            }

            let script = Self.primaryScript(of: token)

            if script == .hiragana || script == .other {
                guard remaining.count >= token.count else { return nil }
                let take = String(remaining.prefix(token.count))
                guard take == token else { return nil }
                let nextRemaining = String(remaining.dropFirst(token.count))
                let consumedAfter = String(hiragana.prefix(hiragana.count - nextRemaining.count))
                guard Self.baselineSegmentsConsumed(consumedAfter, baseline: baselineSegmentReadings) != nil else { return nil }
                remaining = nextRemaining
                pairs.append((take, token))
                continue
            }

            // 漢字・カタカナ: 辞書に token があり、かつ消費後の読みが baseline 境界と整合する最短の長さ
            var readingMatch: String?
            for len in 1...remaining.count {
                let prefix = String(remaining.prefix(len))
                guard azooKey.candidatesForSegment(reading: prefix, leftSideContext: leftSideContext).contains(where: { $0 == token }) else { continue }
                let nextRemaining = String(remaining.dropFirst(len))
                let consumedAfter = String(hiragana.prefix(hiragana.count - nextRemaining.count))
                guard Self.baselineSegmentsConsumed(consumedAfter, baseline: baselineSegmentReadings) != nil else { continue }
                readingMatch = prefix
                break
            }

            if let reading = readingMatch {
                remaining.removeFirst(count: reading.count)
                pairs.append((reading, token))
                continue
            }

            // Fallback: baseline の次セグメント読みをそのまま消費
            let consumedBefore = consumedPrefix()
            guard let segIdx = Self.baselineSegmentsConsumed(consumedBefore, baseline: baselineSegmentReadings),
                  segIdx < baselineSegmentReadings.count else { return nil }
            let segReading = baselineSegmentReadings[segIdx]
            guard remaining.hasPrefix(segReading) else { return nil }
            remaining.removeFirst(count: segReading.count)
            pairs.append((segReading, token))
            let consumedAfterFallback = String(hiragana.prefix(hiragana.count - remaining.count))
            guard Self.baselineSegmentsConsumed(consumedAfterFallback, baseline: baselineSegmentReadings) != nil else {
                return nil
            }
        }

        guard remaining.isEmpty else { return nil }
        return pairs
    }

    // MARK: - Segment boundary inference helpers

    private enum ScriptCluster: Equatable {
        case kanji, katakana, hiragana, other
    }

    nonisolated private static func preprocessLLMText(_ s: String) -> String {
        var chars = Array(s)
        while let c = chars.first, trimOrPunctuation(c) {
            chars.removeFirst()
        }
        while let c = chars.last, trimOrPunctuation(c) {
            chars.removeLast()
        }
        var out = String(chars)
        out.removeAll { ch in
            ch == " " || ch == "\u{3000}" || ch == "\t" || ch == "\n" || ch == "\r"
        }
        return out
    }

    nonisolated private static func trimOrPunctuation(_ c: Character) -> Bool {
        if c.isWhitespace { return true }
        switch c {
        case "。", "、", ".", ",", "．", "，", "・": return true
        default: return false
        }
    }

    nonisolated private static func tokenizeByScript(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentKind: ScriptCluster?
        for ch in s {
            let k = Self.scriptCluster(ch)
            if currentKind == nil {
                currentKind = k
                current.append(ch)
            } else if currentKind == k {
                current.append(ch)
            } else {
                tokens.append(current)
                current = String(ch)
                currentKind = k
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    nonisolated private static func primaryScript(of token: String) -> ScriptCluster {
        guard let f = token.first else { return .other }
        return Self.scriptCluster(f)
    }

    nonisolated private static func scriptCluster(_ ch: Character) -> ScriptCluster {
        for us in ch.unicodeScalars {
            let v = us.value
            if (0x3040...0x309F).contains(v) { return .hiragana }
            if (0x30A0...0x30FF).contains(v) { return .katakana }
            if isKanjiScalar(v) { return .kanji }
            return .other
        }
        return .other
    }

    nonisolated private static func isKanjiScalar(_ v: UInt32) -> Bool {
        switch v {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: return true
        case 0x2F800...0x2FA1F: return true
        default:
            if v >= 0x20000, v <= 0x3134F { return true }
            return false
        }
    }

    /// `consumed` が `baseline` の先頭からの連結と一致するときのセグメント数 `k`（`consumed` が空なら 0）。
    nonisolated private static func baselineSegmentsConsumed(_ consumed: String, baseline: [String]) -> Int? {
        if consumed.isEmpty { return 0 }
        var acc = ""
        for k in 1...baseline.count {
            acc.append(baseline[k - 1])
            if acc == consumed { return k }
            if acc.count > consumed.count { break }
        }
        return nil
    }
}

private extension String {
    public mutating func removeFirst(count n: Int) {
        guard n > 0 else { return }
        let idx = index(startIndex, offsetBy: n, limitedBy: endIndex) ?? endIndex
        removeSubrange(startIndex..<idx)
    }
}
