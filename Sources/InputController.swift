import Cocoa
import InputMethodKit
import os

private let logger = Logger(subsystem: "com.yusuke.inputmethod.ykey", category: "input")

// MARK: - IMKTextInput → TextInputClient アダプタ

private final class IMKTextInputAdapter: TextInputClient {
    private let client: IMKTextInput?

    init(_ sender: Any?) {
        self.client = sender as? IMKTextInput
    }

    func insertText(_ text: String) {
        client?.insertText(text, replacementRange: .notFound)
    }

    func setMarkedText(_ text: String, selectionRange: NSRange) {
        client?.setMarkedText(text, selectionRange: selectionRange, replacementRange: .notFound)
    }

    func setMarkedText(_ text: NSAttributedString, selectionRange: NSRange) {
        client?.setMarkedText(text, selectionRange: selectionRange, replacementRange: .notFound)
    }

    func cursorRect() -> NSRect {
        var rect = NSRect.zero
        client?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }
}

// MARK: - InputController

@objc(InputController)
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

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        candidateWindow.onDelete = { [weak self] text, row in
            self?.handler.db.deleteHistory(output: text)
            self?.candidateWindow.removeCandidate(at: row)
        }
    }

    // MARK: - ライフサイクル

    override func recognizedEvents(_ sender: Any!) -> Int {
        return Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        // ykey は内部で英字/日本語モードを管理する。
        // super を呼ぶと IMK が未対応モードへの切替を試みてイベントルーティングが壊れる。
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        handler.state = CompositionState()
        handler.ignoreNextModeSwitch = true
        candidateWindow.dismiss()
    }

    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        super.deactivateServer(sender)
    }

    // MARK: - イベントハンドリング

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown else { return false }

        let ctx = CandidateContext(
            isVisible: candidateWindow.isVisible,
            selectedRow: candidateWindow.selectedRow,
            selectedText: candidateWindow.selectedText(),
            isExplicitlySelected: candidateWindow.isExplicitlySelected
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

        switch action {
        case .none:
            break
        case .show(let candidates, let historyEnd, let initialRow):
            candidateWindow.show(candidates: candidates, historySectionEnd: historyEnd, initialRow: initialRow, near: adapter.cursorRect())
        case .dismiss:
            candidateWindow.dismiss()
        case .selectNext:
            candidateWindow.selectNext()
            updateMarkedText(client: adapter)
        case .selectPrev:
            candidateWindow.selectPrev()
            updateMarkedText(client: adapter)
        }

        return consumed
    }

    // MARK: - 確定

    override func commitComposition(_ sender: Any!) {
        let adapter = IMKTextInputAdapter(sender)
        let ctx = CandidateContext(
            isVisible: candidateWindow.isVisible,
            selectedRow: candidateWindow.selectedRow,
            selectedText: candidateWindow.selectedText(),
            isExplicitlySelected: candidateWindow.isExplicitlySelected
        )
        handler.commitComposition(client: adapter, candidate: ctx)
        candidateWindow.dismiss()
    }

    // MARK: - プライベートヘルパー

    private func updateMarkedText(client: TextInputClient) {
        if let ss = handler.state.segmentState {
            let str = buildSegmentAttributedString(ss: ss, overrideFocusedText: candidateWindow.selectedText())
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

    /// セグメント全体の NSAttributedString を構築（focused=太い下線、他=細い下線）
    private func buildSegmentAttributedString(ss: SegmentState, overrideFocusedText: String? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, seg) in ss.segments.enumerated() {
            let text = (i == ss.focusedIndex)
                ? (overrideFocusedText ?? seg.selectedText)
                : seg.selectedText
            let style: Int = (i == ss.focusedIndex)
                ? NSUnderlineStyle.thick.rawValue
                : NSUnderlineStyle.single.rawValue
            result.append(NSAttributedString(string: text, attributes: [.underlineStyle: style]))
        }
        return result
    }
}

private extension NSRange {
    static let notFound = NSRange(location: NSNotFound, length: NSNotFound)
}
