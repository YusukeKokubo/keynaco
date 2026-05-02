import AppKit
import FoundationModels
import os

@MainActor
final class GhostTextEngine {

    static let debounceInterval: TimeInterval = 0.1
    static let maxTokens = 30

    private var debounceTimer: Timer?
    private var currentTask: Task<Void, Never>?
    private let ghostWindow: GhostTextWindow
    private let modelAvailable: Bool

    var isAvailable: Bool { modelAvailable }
    var hasGhostText: Bool { ghostWindow.currentText != nil }

    /// ゴーストテキストが表示されたときに呼ばれるコールバック（setMarkedText で IME をアクティブに保つ用途）
    var onShow: (@MainActor (String) -> Void)?

    init(ghostWindow: GhostTextWindow) {
        self.ghostWindow = ghostWindow
        if case .available = SystemLanguageModel.default.availability {
            self.modelAvailable = true
        } else {
            self.modelAvailable = false
        }
    }

    // MARK: - 公開 API

    func schedule(prefix: String, suffix: String, composingText: String, near rect: NSRect) {
        guard isAvailable else {
            #if DEBUG
            os_log(.debug, "GhostText schedule skipped: model unavailable")
            #endif
            return
        }
        #if DEBUG
        os_log(.debug, "GhostText schedule rect=(%{public}.1f,%{public}.1f,%{public}.1f,%{public}.1f) prefix=%{public}@",
               rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
               String(prefix.suffix(20)))
        #endif
        cancelInternal()
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.debounceInterval, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire(prefix: prefix, suffix: suffix, composingText: composingText, near: rect) }
        }
    }

    func cancel() {
        cancelInternal()
        ghostWindow.dismiss()
    }

    /// Tab 確定時。true を返したら consumed = true にする。
    func confirm(into client: TextInputClient) -> Bool {
        guard let text = ghostWindow.currentText else { return false }
        cancelInternal()
        ghostWindow.dismiss()
        client.insertText(text)
        return true
    }

    // MARK: - Private

    private func cancelInternal() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        currentTask?.cancel()
        currentTask = nil
    }

    private func fire(prefix: String, suffix: String, composingText: String, near rect: NSRect) {
        guard modelAvailable else { return }
        #if DEBUG
        os_log(.debug, "GhostText fire: sending to Apple Intelligence")
        #endif
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = LanguageModelSession()
                let text = try await Self.fetchCompletion(
                    session: session, prefix: prefix, suffix: suffix
                )
                #if DEBUG
                os_log(.debug, "GhostText response: '%{public}@' cancelled=%{public}@",
                       text, "\(Task.isCancelled)")
                #endif
                guard !Task.isCancelled, !text.isEmpty else { return }
                self.ghostWindow.show(text: text, composingText: composingText, near: rect)
                self.onShow?(text)
                #if DEBUG
                os_log(.debug, "GhostText window shown at (%{public}.1f,%{public}.1f)",
                       rect.origin.x, rect.origin.y)
                #endif
            } catch {
                #if DEBUG
                os_log(.debug, "GhostText error: %{public}@", "\(error)")
                #endif
            }
        }
    }

    // MARK: - Foundation Models リクエスト

    private static func fetchCompletion(
        session: LanguageModelSession,
        prefix: String,
        suffix: String
    ) async throws -> String {
        let prompt = buildPrompt(prefix: prefix, suffix: suffix)
        let options = GenerationOptions(maximumResponseTokens: maxTokens)
        let response = try await session.respond(to: prompt, options: options)
        return postProcess(response.content)
    }

    private static func buildPrompt(prefix: String, suffix: String) -> String {
            return """
            次の日本語テキストの末尾を補完してください。末尾の文字列のみ回答して。

            \(prefix)[空白]\(suffix)
            """
    }

    private static func postProcess(_ text: String) -> String {
        (text.components(separatedBy: "\n").first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
