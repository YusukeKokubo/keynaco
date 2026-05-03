import Cocoa
import InputMethodKit

// MARK: - IMKTextInput → TextInputClient アダプタ

private final class IMKTextInputAdapter: TextInputClient, @unchecked Sendable {
    private let client: IMKTextInput?
    private(set) var didInsertText = false

    init(_ sender: Any?) {
        self.client = sender as? IMKTextInput
    }

    private(set) var lastInsertedText: String = ""

    func insertText(_ text: String) {
        didInsertText = true
        lastInsertedText = text
        // insertText は常に @MainActor の InputController 経由で呼ばれる
        #if DEBUG
        MainActor.assumeIsolated { EventViewerWindow.shared.addCommit(text) }
        #endif
        client?.insertText(text, replacementRange: .notFound)
    }

    func setMarkedText(_ text: String, selectionRange: NSRange) {
        client?.setMarkedText(text, selectionRange: selectionRange, replacementRange: .notFound)
    }

    func setMarkedText(_ text: NSAttributedString, selectionRange: NSRange) {
        client?.setMarkedText(text, selectionRange: selectionRange, replacementRange: .notFound)
    }

    func selectedRange() -> NSRange {
        client?.selectedRange() ?? NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ text: String, selectionRange: NSRange, replacementRange: NSRange) {
        client?.setMarkedText(text, selectionRange: selectionRange, replacementRange: replacementRange)
    }

    func cursorRect() -> NSRect {
        var rect = NSRect.zero
        client?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }

    // マークドテキストなし（確定後）のカーソル位置を selectedRange から取得する
    func cursorRectAtCursor() -> NSRect {
        guard let c = client else { return .zero }
        let sel = c.selectedRange()
        guard sel.location != NSNotFound else { return .zero }
        var rect = NSRect.zero
        c.attributes(forCharacterIndex: sel.location, lineHeightRectangle: &rect)
        return rect
    }

    func surroundingText(maxLength: Int = 200) -> (prefix: String, suffix: String) {
        guard let c = client else { return ("", "") }
        let sel = c.selectedRange()
        guard sel.location != NSNotFound else { return ("", "") }
        let prefixStart = max(0, sel.location - maxLength)
        var prefixActual = NSRange()
        let prefix = c.string(
            from: NSRange(location: prefixStart, length: sel.location - prefixStart),
            actualRange: &prefixActual
        ) ?? ""
        var suffixActual = NSRange()
        let suffix = c.string(
            from: NSRange(location: sel.location + sel.length, length: maxLength),
            actualRange: &suffixActual
        ) ?? ""
        return (prefix, suffix)
    }
}

// MARK: - InputController

@objc(InputController)
@MainActor
class InputController: IMKInputController {

    private lazy var handler: InputHandler = InputHandler()

    private static let candidateWindow: CandidateWindow = {
        let w = CandidateWindow(
            contentRect: .zero, styleMask: [.borderless],
            backing: .buffered, defer: true
        )
        return w
    }()

    private var candidateWindow: CandidateWindow { Self.candidateWindow }

    @MainActor private static let ghostWindow: GhostTextWindow = GhostTextWindow()
    @MainActor private static let _ghostTextEngine: GhostTextEngine = GhostTextEngine(ghostWindow: ghostWindow)
    private var ghostTextEngine: GhostTextEngine { Self._ghostTextEngine }

    // ゴーストテキスト表示後の setMarkedText 用に最後の sender を保持する
    private var lastSender: Any?

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        candidateWindow.onDelete = { [weak self] (text: String, row: Int) in
            self?.handler.db.deleteHistory(output: text)
            self?.candidateWindow.removeCandidate(at: row)
        }
    }

    // MARK: - ライフサイクル

    override func recognizedEvents(_ sender: Any!) -> Int {
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        return Int(mask.rawValue)
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "設定...", action: #selector(openSettings), keyEquivalent: ","))
        return menu
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showSettings()
    }

    override func showPreferences(_ sender: Any!) {
        SettingsWindowController.shared.showSettings()
    }

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        // keynaco は内部で英字/日本語モードを管理する。
        // super を呼ぶと IMK が未対応モードへの切替を試みてイベントルーティングが壊れる。
    }

    override func activateServer(_ sender: Any!) {
        ghostTextEngine.cancel()
        super.activateServer(sender)
        handler.state = CompositionState()
        handler.committedHistory = []
        handler.isSuccessorMode = false
        handler.successorFirstChar = nil
        handler.ignoreNextModeSwitch = true
        candidateWindow.dismiss()
        // ゼロ幅スペースをマークドテキストにセットして IME をアクティブに保つ。
        // これにより Tab がアプリに横取りされず IME に届くようになる。
        ghostTextEngine.onShow = { [weak self] _ in
            guard let self, let s = self.lastSender else { return }
            IMKTextInputAdapter(s).setMarkedText(
                "\u{200B}", selectionRange: NSRange(location: 1, length: 0)
            )
        }
    }

    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        super.deactivateServer(sender)
    }

    // MARK: - イベントハンドリング

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event else { return false }
        lastSender = sender

        // Caps Lock でモード切替（LED ON = 英字モード、LED OFF = 日本語モード）
        if event.type == .flagsChanged && event.keyCode == KeyCode.capsLock {
            InputHandler.isAsciiMode = event.modifierFlags.contains(.capsLock)
            return false
        }

        guard event.type == .keyDown else { return false }

        // Ghost text: Tab で確定、その他のキーはキャンセル
        if event.keyCode == KeyCode.tab && ghostTextEngine.hasGhostText {
            candidateWindow.dismiss()
            return ghostTextEngine.confirm(into: IMKTextInputAdapter(sender))
        }
        // ゴーストテキストが表示中だった場合はマークドテキストもクリアする
        if ghostTextEngine.hasGhostText {
            IMKTextInputAdapter(sender).setMarkedText(
                "", selectionRange: NSRange(location: 0, length: 0)
            )
        }
        ghostTextEngine.cancel()

        let chars = event.characters ?? ""
        let baseChars = event.charactersIgnoringModifiers ?? ""
        let mods = event.modifierFlags
        #if DEBUG
        EventViewerWindow.shared.addEvent(
            keyCode: event.keyCode, chars: chars, baseChars: baseChars,
            mods: mods, bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
        #endif

        let ctx = CandidateContext(
            isVisible: candidateWindow.isVisible,
            selectedRow: candidateWindow.selectedRow,
            selectedText: candidateWindow.selectedText(),
            isExplicitlySelected: candidateWindow.isExplicitlySelected,
            historyEnd: candidateWindow.historySectionEnd,
            fixedEnd: candidateWindow.fixedRowCount
        )
        let adapter = IMKTextInputAdapter(sender)

        let (consumed, action) = handler.handle(
            keyCode: event.keyCode,
            characters: event.characters,
            baseCharacters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            candidate: ctx,
            client: adapter
        )

        #if DEBUG
        let actionName = "\(action)".split(separator: "(").first.map(String.init) ?? "\(action)"
        EventViewerWindow.shared.updateResult(consumed: consumed, action: actionName)
        #endif

        // 確定直後（insertText が呼ばれた）にゴーストテキストをスケジュール
        if adapter.didInsertText {
            let engine = Self._ghostTextEngine
            if engine.isAvailable && !InputHandler.isAsciiMode {
                let (prefix, suffix) = adapter.surroundingText()
                // Electron 系は surroundingText が空を返すため、確定テキスト自体を prefix にフォールバック
                let effectivePrefix = prefix.isEmpty ? adapter.lastInsertedText : prefix
                if !effectivePrefix.isEmpty {
                    engine.schedule(prefix: effectivePrefix, suffix: suffix, composingText: "", recentIMEWords: handler.committedHistory, near: adapter.cursorRectAtCursor())
                }
            }
        }

        switch action {
        case .none:
            break
        case .show(let candidates, let historyEnd, let initialRow, let predictionEnd, let fixedEnd):
            #if DEBUG
            EventViewerWindow.shared.addCandidates(candidates, selectedIndex: initialRow)
            #endif
            candidateWindow.show(candidates: candidates, historySectionEnd: historyEnd, initialRow: initialRow, predictionEnd: predictionEnd, fixedSectionEnd: fixedEnd, near: adapter.cursorRect())
            if handler.isSuccessorMode {
                // 格助詞を選択候補としてマークドテキストに設定する。
                // 空文字ではなく実際のテキストを持つことで Electron 系アプリが
                // Enter を IME に転送するようになる。
                let markedText = candidates.isEmpty ? "" : candidates[min(initialRow, candidates.count - 1)]
                adapter.setMarkedText(markedText, selectionRange: NSRange(location: markedText.count, length: 0))
            }
        case .dismiss:
            candidateWindow.dismiss()
        case .selectNext:
            candidateWindow.selectNext()
            if handler.isSuccessorMode || handler.isBracketMode {
                let text = candidateWindow.selectedText() ?? ""
                adapter.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0))
            } else {
                updateMarkedText(client: adapter)
            }
        case .selectPrev:
            candidateWindow.selectPrev()
            if handler.isSuccessorMode || handler.isBracketMode {
                let text = candidateWindow.selectedText() ?? ""
                adapter.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0))
            } else {
                updateMarkedText(client: adapter)
            }
        case .deleteSelected:
            let row = candidateWindow.selectedRow
            if let text = candidateWindow.selectedText() {
                handler.db.deleteHistory(output: text)
                candidateWindow.removeCandidate(at: row)
            }
        }

        return consumed
    }

    // MARK: - 確定

    override func commitComposition(_ sender: Any!) {
        ghostTextEngine.cancel()
        // Successor モード中で組成がない場合は system-triggered commit をスキップ
        // (insertText の副作用で system が commitComposition を呼ぶことがある)
        if handler.isSuccessorMode && handler.state.composingText.isEmpty && !handler.state.isSegmentMode {
            return
        }
        let adapter = IMKTextInputAdapter(sender)
        let ctx = CandidateContext(
            isVisible: candidateWindow.isVisible,
            selectedRow: candidateWindow.selectedRow,
            selectedText: candidateWindow.selectedText(),
            isExplicitlySelected: candidateWindow.isExplicitlySelected,
            historyEnd: candidateWindow.historySectionEnd,
            fixedEnd: candidateWindow.fixedRowCount
        )
        handler.commitComposition(client: adapter, candidate: ctx)
        handler.isSuccessorMode = false
        handler.successorFirstChar = nil
        handler.bracketCandidates = nil
        candidateWindow.dismiss()
    }

    // MARK: - プライベートヘルパー

    private func updateMarkedText(client: TextInputClient) {
        if let ss = handler.state.segmentState {
            let str = ss.attributedString(overrideFocusedText: candidateWindow.selectedText())
            client.setMarkedText(str, selectionRange: NSRange(location: str.length, length: 0))
        } else {
            let text: String
            if candidateWindow.isVisible, let selected = candidateWindow.selectedText() {
                text = selected + handler.state.pendingRomaji
            } else {
                text = handler.state.composingText
            }
            client.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0))
        }
    }

}

private extension NSRange {
    static let notFound = NSRange(location: NSNotFound, length: NSNotFound)
}
