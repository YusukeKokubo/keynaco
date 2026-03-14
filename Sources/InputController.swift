import Cocoa
import InputMethodKit

class InputController: IMKInputController {

    // 現在の未確定バッファ
    private var buffer = ""

    // 候補ウィンドウ（サーバーが確定してから lazy 生成）
    private lazy var candidatesWindow: IMKCandidates = {
        IMKCandidates(server: gServer!, panelType: kIMKSingleColumnScrollingCandidatePanel)
    }()

    // MARK: - キー入力

    override func inputText(_ string: String!, key keyCode: Int, modifiers flags: Int, client sender: Any!) -> Bool {
        guard let ch = string, !ch.isEmpty else { return false }

        switch keyCode {
        case 51: // Delete/Backspace
            return handleBackspace(client: sender)
        case 36: // Return
            return handleReturn(client: sender)
        case 53: // Escape
            return handleEscape(client: sender)
        default:
            break
        }

        // 制御文字・修飾キー単体は無視
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(flags))
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return false }

        buffer += ch
        updateMarkedText(client: sender)

        if buffer.count >= 2 {
            refreshCandidates()
        }

        return true
    }

    // MARK: - 候補リスト供給（IMKCandidates が呼び出す）

    override func candidates(_ sender: Any!) -> [Any]! {
        DatabaseManager.shared.fetchCandidates(prefix: buffer)
    }

    // MARK: - 候補選択

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        let output = candidateString.string
        DatabaseManager.shared.record(input: buffer, output: output)
        commit(text: output, client: client())
    }

    // MARK: - 確定

    override func commitComposition(_ sender: Any!) {
        guard !buffer.isEmpty else { return }
        DatabaseManager.shared.record(input: buffer, output: buffer)
        commit(text: buffer, client: sender)
    }

    // MARK: - Private helpers

    private func refreshCandidates() {
        let hits = DatabaseManager.shared.fetchCandidates(prefix: buffer)
        if hits.isEmpty {
            candidatesWindow.hide()
        } else {
            candidatesWindow.update()
            candidatesWindow.show(kIMKLocateCandidatesLeftHint)
        }
    }

    private func updateMarkedText(client: Any?) {
        guard let c = client as? IMKTextInput else { return }
        if buffer.isEmpty {
            c.insertText("", replacementRange: .notFound)
        } else {
            c.setMarkedText(
                buffer,
                selectionRange: NSRange(location: buffer.count, length: 0),
                replacementRange: .notFound
            )
        }
    }

    private func commit(text: String, client: Any?) {
        guard let c = client as? IMKTextInput else { return }
        c.insertText(text, replacementRange: .notFound)
        buffer = ""
        candidatesWindow.hide()
    }

    private func handleBackspace(client: Any?) -> Bool {
        guard !buffer.isEmpty else { return false }
        buffer.removeLast()
        updateMarkedText(client: client)
        if buffer.count >= 2 { refreshCandidates() } else { candidatesWindow.hide() }
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
        updateMarkedText(client: client)
        candidatesWindow.hide()
        return true
    }
}

// MARK: - NSRange convenience

private extension NSRange {
    static let notFound = NSRange(location: NSNotFound, length: NSNotFound)
}
