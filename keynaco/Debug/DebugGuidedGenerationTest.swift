#if DEBUG

import AppKit
import FoundationModels

// MARK: - @Generable テスト型

@Generable
private struct GGSummary {
    @Guide(description: "入力テキストの一行要約（日本語）")
    var summary: String
    @Guide(description: "YES or NO")
    var isJapanese: String
}

// MARK: - DebugGuidedGenerationTestWindow

@MainActor
final class DebugGuidedGenerationTestWindow: NSWindow {
    static let shared = DebugGuidedGenerationTestWindow()

    private let statusLabel = NSTextField(labelWithString: "待機中")
    private let resultView = NSTextView(frame: .zero)
    private let runButton = NSButton(title: "Run Guided Generation", target: nil, action: nil)
    private var runTask: Task<Void, Never>?

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Guided Generation テスト（本体アプリ）"
        isReleasedWhenClosed = false
        setupUI()
    }

    private func setupUI() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView = root

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        runButton.bezelStyle = .rounded
        runButton.translatesAutoresizingMaskIntoConstraints = false
        runButton.target = self
        runButton.action = #selector(onRun)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        resultView.isEditable = false
        resultView.isSelectable = true
        resultView.isRichText = false
        resultView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        resultView.autoresizingMask = [.width]
        scroll.documentView = resultView

        root.addSubview(statusLabel)
        root.addSubview(runButton)
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),

            runButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            runButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
    }

    @objc private func onRun() {
        runTask?.cancel()
        runButton.isEnabled = false
        statusLabel.stringValue = "実行中..."
        resultView.string = ""

        runTask = Task { @MainActor in
            await runTest()
            runButton.isEnabled = true
        }
    }

    private func runTest() async {
        append("=== Guided Generation テスト ===\n")
        append("本体アプリのサンドボックスで respond(generating:) を呼び出す\n\n")

        guard case .available = SystemLanguageModel.default.availability else {
            statusLabel.stringValue = "❌ Apple Intelligence 利用不可"
            append("SystemLanguageModel.default.availability: unavailable\n")
            return
        }
        append("Apple Intelligence: available ✅\n\n")

        let session = LanguageModelSession(model: SystemLanguageModel.default)
        let prompt = "次のテキストについて回答してください: 「今日はSwiftでIMEを開発した。コーヒーを3杯飲んだ。」"

        append("プロンプト: \(prompt)\n\n")
        append("respond(generating: GGSummary.self) 呼び出し中...\n")

        do {
            let result = try await session.respond(to: prompt, generating: GGSummary.self)
            statusLabel.stringValue = "✅ 成功"
            append("--- 結果 ---\n")
            append("summary: \(result.content.summary)\n")
            append("isJapanese: \(result.content.isJapanese)\n")
            append("\nGuided Generation は本体アプリで動作する ✅\n")
        } catch {
            statusLabel.stringValue = "❌ エラー"
            append("--- エラー ---\n")
            append("\(error)\n")
            append("\nerror.localizedDescription: \(error.localizedDescription)\n")
            if let nsError = error as? NSError {
                append("domain: \(nsError.domain)\n")
                append("code: \(nsError.code)\n")
            }
        }
    }

    private func append(_ text: String) {
        resultView.string += text
        resultView.scrollToEndOfDocument(nil)
    }

    func show() {
        if !isVisible { center() }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#endif
