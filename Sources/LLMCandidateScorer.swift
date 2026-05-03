import Foundation
import FoundationModels

/// 変換候補を直前文脈に照らしてオンデバイス LLM が「最も自然な」1 件を選ぶ。
@MainActor
final class LLMCandidateScorer {
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

    /// - Parameter candidates: プロンプトに並べる候補文字列（最大10件想定）。
    /// - Parameter onResult: 成功時のみ呼ぶ。**引数は `candidates` 配列の 0-based インデックス**。
    ///   呼び出し側はこれを `pendingF1GlobalIndices` でグローバル行へ写像する。
    func score(
        candidates: [String],
        context: String,
        reading: String,
        onResult: @escaping (Int) -> Void
    ) {
        guard case .available = SystemLanguageModel.default.availability else { return }
        guard !candidates.isEmpty else { return }
        cancel()
        let prompt = Self.buildPrompt(context: context, reading: reading, candidates: candidates)
        let n = candidates.count
        task = Task { @MainActor [session] in
            do {
                let response = try await session.respond(to: prompt)
                guard let idx = Self.parseChosenIndex(from: response, maxCount: n) else { return }
                onResult(idx)
            } catch {}
        }
    }

    private static func buildPrompt(context: String, reading: String, candidates: [String]) -> String {
        var lines = """
        【文脈】\(context)
        【読み】\(reading)
        【候補】

        """
        for (i, c) in candidates.enumerated() {
            lines += "\(i + 1). \(c)\n"
        }
        lines += "\n最も自然な候補の番号を1つだけ答えてください。"
        return lines
    }

    private static func parseChosenIndex<Content>(from response: LanguageModelSession.Response<Content>, maxCount: Int) -> Int? {
        let text: String
        if let s = response.content as? String {
            text = s
        } else {
            return nil
        }
        guard maxCount >= 1 else { return nil }
        guard let firstInt = extractFirstInteger(from: text) else { return nil }
        guard firstInt >= 1, firstInt <= maxCount else { return nil }
        return firstInt - 1
    }

    /// 文字列から最初に現れる十進整数（負号なし）。
    private static func extractFirstInteger(from text: String) -> Int? {
        var num = ""
        var started = false
        for ch in text {
            if ch.isWholeNumber {
                num.append(ch)
                started = true
            } else if started {
                break
            }
        }
        guard !num.isEmpty, let v = Int(num) else { return nil }
        return v
    }
}
