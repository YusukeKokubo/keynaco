import AppKit
import FoundationModels
import os

@MainActor
final class GhostTextEngine {

    static let debounceInterval: TimeInterval = 0.1
    static let maxTokens = 8
    static let maxGhostChars = 5

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

    func schedule(prefix: String, suffix: String, composingText: String, recentIMEWords: [String] = [], near rect: NSRect) {
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
            MainActor.assumeIsolated { self?.fire(prefix: prefix, suffix: suffix, composingText: composingText, recentIMEWords: recentIMEWords, near: rect) }
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

    private func fire(prefix: String, suffix: String, composingText: String, recentIMEWords: [String], near rect: NSRect) {
        guard modelAvailable else { return }
        #if DEBUG
        os_log(.debug, "GhostText fire: sending to Apple Intelligence")
        #endif
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = LanguageModelSession(instructions:
                    "日本語IME補完。入力の末尾に続く助詞か名詞1語のみ出力。テキストを繰り返さない。"
                )
                let text = try await Self.fetchCompletion(
                    session: session, prefix: prefix, recentIMEWords: recentIMEWords
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
        recentIMEWords: [String]
    ) async throws -> String {
        let prompt = buildPrompt(prefix: prefix, recentIMEWords: recentIMEWords)
        let options = GenerationOptions(maximumResponseTokens: maxTokens)
        let response = try await session.respond(to: prompt, options: options)
        return postProcess(response.content, prefix: prefix, recentIMEWords: recentIMEWords)
    }

    private static func buildPrompt(prefix: String, recentIMEWords: [String]) -> String {
        // surroundingText が十分長ければそちらを優先、短ければ IME 確定履歴で補完
        let imeHistory = recentIMEWords.joined()
        let ctx = prefix.count >= imeHistory.count ? prefix : imeHistory
        return "\(String(ctx.suffix(30)))___"
    }

    private static func postProcess(_ text: String, prefix: String, recentIMEWords: [String]) -> String {
        let line = (text.components(separatedBy: "\n").first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // プロンプトに使ったコンテキスト末尾との重複を除去
        var cleaned = line
        let imeHistory = recentIMEWords.joined()
        let effective = prefix.count >= imeHistory.count ? prefix : imeHistory
        let ctx = String(effective.suffix(30))
        for length in stride(from: min(ctx.count, cleaned.count), through: 1, by: -1) {
            let tail = String(ctx.suffix(length))
            if cleaned.hasPrefix(tail) {
                cleaned = String(cleaned.dropFirst(tail.count))
                break
            }
        }
        // prefix 内にすでに含まれる語は不要
        if !cleaned.isEmpty && prefix.contains(cleaned) { return "" }

        let stopChars: Set<Character> = ["。", "、", "！", "？", "…", ".", ",", "!", "?"]
        var result = ""
        for ch in cleaned {
            if stopChars.contains(ch) { break }
            result.append(ch)
        }
        if result.isEmpty { return "" }

        // 複合助詞はそのまま返す
        let compound = ["から", "まで", "より", "には", "では", "への", "との", "にも", "でも"]
        for cp in compound { if result.hasPrefix(cp) { return cp } }
        // 単助詞は1文字
        let particles: Set<Character> = ["が", "を", "に", "は", "で", "と", "の", "へ", "も", "か"]
        if let first = result.first, particles.contains(first) { return String(result.prefix(1)) }
        // 名詞等は4文字まで
        return String(result.prefix(maxGhostChars - 1))
    }
}
