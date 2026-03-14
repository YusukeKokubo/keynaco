import Cocoa
import InputMethodKit

@objc(InputController)
class InputController: IMKInputController {

    private var buffer = ""
    private var currentCandidates: [String] = []

    private static let candidateWindow = CandidateWindow(
        contentRect: .zero, styleMask: [.borderless],
        backing: .buffered, defer: true
    )

    private var candidateWindow: CandidateWindow { Self.candidateWindow }

    // MARK: - イベントハンドリング

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown else { return false }

        let keyCode = event.keyCode

        // 候補ウィンドウ表示中
        if candidateWindow.isVisible {
            switch keyCode {
            case 48: // Tab
                candidateWindow.selectNext()
                updateMarkedText(client: sender)
                return true
            case 36: // Return
                return confirmSelection(client: sender)
            case 53: // Escape
                return handleEscape(client: sender)
            case 51: // Backspace
                return handleBackspace(client: sender)
            default:
                break
            }
        } else {
            switch keyCode {
            case 36:
                return handleReturn(client: sender)
            case 53:
                return handleEscape(client: sender)
            case 51:
                return handleBackspace(client: sender)
            default:
                break
            }
        }

        // 修飾キー付きはスルー
        let modifiers = event.modifierFlags
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return false }

        guard let chars = event.characters, !chars.isEmpty else { return false }

        buffer += chars
        updateMarkedText(client: sender)

        if buffer.count >= 2 {
            refreshCandidates(client: sender)
        } else {
            candidateWindow.dismiss()
        }

        return true
    }

    // MARK: - 確定

    override func commitComposition(_ sender: Any!) {
        guard !buffer.isEmpty else { return }
        DatabaseManager.shared.record(input: buffer, output: buffer)
        commit(text: buffer, client: sender)
    }

    // MARK: - Private helpers

    private func refreshCandidates(client: Any?) {
        currentCandidates = DatabaseManager.shared.fetchCandidates(prefix: buffer)
        if currentCandidates.isEmpty {
            candidateWindow.dismiss()
            return
        }

        // カーソル位置を取得
        var cursorRect = NSRect.zero
        if let c = client as? IMKTextInput {
            c.attributes(forCharacterIndex: 0, lineHeightRectangle: &cursorRect)
        }
        candidateWindow.show(candidates: currentCandidates, near: cursorRect)
    }

    private func confirmSelection(client: Any?) -> Bool {
        guard !buffer.isEmpty else { return false }
        if let selected = candidateWindow.selectedText() {
            DatabaseManager.shared.record(input: buffer, output: selected)
            commit(text: selected, client: client)
        } else {
            commitComposition(client)
        }
        return true
    }

    private func displayText() -> String {
        if candidateWindow.isVisible, let selected = candidateWindow.selectedText() {
            return selected
        }
        return buffer
    }

    private func updateMarkedText(client: Any?) {
        guard let c = client as? IMKTextInput else { return }
        let text = displayText()
        if text.isEmpty {
            c.insertText("", replacementRange: .notFound)
        } else {
            c.setMarkedText(
                text,
                selectionRange: NSRange(location: text.count, length: 0),
                replacementRange: .notFound
            )
        }
    }

    private func commit(text: String, client: Any?) {
        guard let c = client as? IMKTextInput else { return }
        c.insertText(text, replacementRange: .notFound)
        buffer = ""
        currentCandidates = []
        candidateWindow.dismiss()
    }

    private func handleBackspace(client: Any?) -> Bool {
        guard !buffer.isEmpty else { return false }
        buffer.removeLast()
        updateMarkedText(client: client)
        if buffer.count >= 2 {
            refreshCandidates(client: client)
        } else {
            candidateWindow.dismiss()
        }
        return true
    }

    private func handleReturn(client: Any?) -> Bool {
        guard !buffer.isEmpty else { return false }
        commitComposition(client)
        return true
    }

    private func handleEscape(client: Any?) -> Bool {
        guard !buffer.isEmpty else { return false }
        buffer = ""
        currentCandidates = []
        updateMarkedText(client: client)
        candidateWindow.dismiss()
        return true
    }
}

private extension NSRange {
    static let notFound = NSRange(location: NSNotFound, length: NSNotFound)
}
