import Foundation
import FoundationModels

/// セグメントモード用：`composedHiragana` 全体をオンデバイス LLM で一括変換する。
@MainActor
public final class LLMSegmentConverter {
    /// `composedHiragana.count` がこの値以上のときだけプリフェッチする（`> 5` 文字）。
    public static let segmentPrefetchMinHiraganaCount = 6

    private var task: Task<Void, Never>?
    /// プリフェッチ／`convert` の Task を世代管理し、キャンセル済みクロージャが `self.task` を壊さないようにする。
    private var taskGeneration: UInt64 = 0
    private lazy var session: LanguageModelSession = LanguageModelSession(model: SystemLanguageModel.default) {
        "あなたは日本語入力メソッドの補助モジュールです。指示された形式だけを出力し、説明文は書かないでください。"
    }

    /// 直近の `prefetch` が対象としている読み（末尾追記ではタスクを捨てずに更新する）。
    private var pendingHiragana: String?
    /// `takePrefetchIfMatching` まで保持する完了結果。
    private var completedPrefetch: (hiragana: String, text: String)?

    public init() {}

    public func cancel() {
        taskGeneration += 1
        task?.cancel()
        task = nil
        completedPrefetch = nil
        pendingHiragana = nil
    }

    /// 組成中の読みが十分長いとき、Space 前に LLM 推論を先行開始する。
    public func prefetch(hiragana: String) {
        guard case .available = SystemLanguageModel.default.availability else {
            cancel()
            return
        }
        guard hiragana.count >= Self.segmentPrefetchMinHiraganaCount else {
            cancel()
            return
        }
        // 同一読みで既に完了済み・タスクなしなら再推論しない
        if hiragana == pendingHiragana,
           task == nil,
           let done = completedPrefetch,
           done.hiragana == hiragana {
            return
        }
        // 末尾追記のみで推論が進行中なら cancel せず pending だけ更新（完了済み task==nil のときは再起動が必要）
        if let prev = pendingHiragana,
           prev.count >= Self.segmentPrefetchMinHiraganaCount,
           hiragana.hasPrefix(prev),
           task != nil {
            pendingHiragana = hiragana
            return
        }
        restartPrefetch(for: hiragana)
    }

    /// Space 入室時: `hiragana` がプリフェッチ完了と一致すれば変換テキストを返しキャッシュを消費する。常に進行中タスクは止める。
    public func takePrefetchIfMatching(hiragana: String) -> String? {
        taskGeneration += 1
        task?.cancel()
        task = nil
        pendingHiragana = nil
        guard let (h, t) = completedPrefetch, h == hiragana else {
            return nil
        }
        completedPrefetch = nil
        return t.isEmpty ? nil : t
    }

    /// 変換結果のテキストのみ（失敗時は空文字）。デバッグソケット等用。本番 IME のセグメント入室では `prefetch` / `takePrefetchIfMatching` を使う。
    public func convert(hiragana: String, onResult: @escaping (String) -> Void) {
        guard case .available = SystemLanguageModel.default.availability else {
            onResult("")
            return
        }
        cancel()
        let prompt = Self.buildPrompt(hiragana: hiragana)
        let generation = taskGeneration
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else {
                if generation == self.taskGeneration {
                    self.task = nil
                }
                return
            }
            do {
                let response = try await self.session.respond(to: prompt)
                guard !Task.isCancelled else {
                    if generation == self.taskGeneration {
                        self.task = nil
                    }
                    return
                }
                let text = Self.parseText(from: response)
                onResult(text)
                if generation == self.taskGeneration {
                    self.task = nil
                }
            } catch {
                onResult("")
                if generation == self.taskGeneration {
                    self.task = nil
                }
            }
        }
    }

    private func restartPrefetch(for hiragana: String) {
        task?.cancel()
        task = nil
        completedPrefetch = nil
        pendingHiragana = hiragana
        taskGeneration += 1
        let generation = taskGeneration
        let promptHiragana = hiragana
        let prompt = Self.buildPrompt(hiragana: promptHiragana)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else {
                if generation == self.taskGeneration {
                    self.task = nil
                }
                return
            }
            do {
                let response = try await self.session.respond(to: prompt)
                guard !Task.isCancelled else {
                    if generation == self.taskGeneration {
                        self.task = nil
                    }
                    return
                }
                let text = Self.parseText(from: response)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if promptHiragana != self.pendingHiragana {
                    if let p = self.pendingHiragana, p.count >= Self.segmentPrefetchMinHiraganaCount {
                        self.restartPrefetch(for: p)
                    } else if generation == self.taskGeneration {
                        self.task = nil
                    }
                    return
                }
                guard !trimmed.isEmpty else {
                    if generation == self.taskGeneration {
                        self.task = nil
                    }
                    return
                }
                guard generation == self.taskGeneration else { return }
                self.completedPrefetch = (promptHiragana, trimmed)
                self.task = nil
            } catch {
                if generation == self.taskGeneration {
                    self.task = nil
                }
            }
        }
    }

    /// ユニットテスト用: 完了キャッシュを直接入れる（本番コードからは呼ばない）。
    internal func _testing_seedCompletedPrefetch(hiragana: String, text: String) {
        completedPrefetch = (hiragana, text)
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
    mutating func removeFirst(count n: Int) {
        guard n > 0 else { return }
        let idx = index(startIndex, offsetBy: n, limitedBy: endIndex) ?? endIndex
        removeSubrange(startIndex..<idx)
    }
}
