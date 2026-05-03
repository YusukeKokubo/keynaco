import Foundation
import FoundationModels

/// F4: 確定直後のカーソル前文をオンデバイス LLM で検査し、誤変換の可能性を通知する。
@MainActor
final class LLMMisconversionChecker {
    private var debounceTask: Task<Void, Never>?
    private var llmTask: Task<Void, Never>?
    private lazy var session: LanguageModelSession = LanguageModelSession(model: SystemLanguageModel.default) {
        """
        あなたは日本語入力メソッドの補助モジュールです。指示された形式だけを出力し、説明文は書かないでください。
        """
    }

    /// テスト用フック（任意）。通知とは別に呼ばれる。
    var onIssueFound: ((String) -> Void)?
    /// テスト用フック（任意）。通知とは別に呼ばれる。
    var onClear: (() -> Void)?

    /// 進行中のデバウンス・LLM タスクを止める。`suppressClearNotification == false` のときクリア通知を送る。
    func cancel(suppressClearNotification: Bool = false) {
        debounceTask?.cancel()
        llmTask?.cancel()
        debounceTask = nil
        llmTask = nil
        if !suppressClearNotification {
            deliverClear()
        }
    }

    /// カーソル直前の確定済みテキスト断片（最大 200 文字想定）を検査する。0.5 秒デバウンス。
    func check(surroundingPrefix: String) {
        guard case .available = SystemLanguageModel.default.availability else { return }

        cancel(suppressClearNotification: true)

        let trimmed = surroundingPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5 else {
            deliverClear()
            return
        }

        let captured = trimmed
        debounceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            runLLMCheck(text: captured)
        }
    }

    private func runLLMCheck(text: String) {
        llmTask?.cancel()
        llmTask = Task { @MainActor [session] in
            do {
                let prompt = Self.buildPrompt(text: text)
                let response = try await session.respond(to: prompt)
                guard !Task.isCancelled else { return }
                if let issue = Self.parseIssue(from: response), !issue.isEmpty {
                    deliverIssue(issue)
                } else {
                    deliverClear()
                }
            } catch {}
        }
    }

    private func deliverIssue(_ detail: String) {
        onIssueFound?(detail)
        NotificationCenter.default.post(
            name: .keynacoMisconversionIssueFound,
            object: nil,
            userInfo: ["detail": detail]
        )
    }

    private func deliverClear() {
        onClear?()
        NotificationCenter.default.post(name: .keynacoMisconversionCleared, object: nil)
    }

    private static func buildPrompt(text: String) -> String {
        """
        次の日本語テキストに誤変換や不自然な表現があれば、箇所と修正案を指摘してください。
        問題がなければ「OK」とだけ答えてください。
        \(text)
        """
    }

    private static func parseIssue(from response: LanguageModelSession.Response<String>) -> String? {
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text.range(of: "^\\s*OK[。．.]?\\s*$", options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        return text
    }
}
