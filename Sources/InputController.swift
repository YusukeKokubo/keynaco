import Cocoa
import InputMethodKit

@objc(InputController)
class InputController: IMKInputController {

    private var composedHiragana = ""
    private var pendingRomaji = ""
    private var currentCandidates: [String] = []

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
            DatabaseManager.shared.deleteHistory(output: text)
            self?.candidateWindow.removeCandidate(at: row)
        }
    }

    /// マークドテキストに表示する未確定文字列
    private var composingText: String {
        composedHiragana + pendingRomaji
    }

    // MARK: - イベントハンドリング

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown else { return false }

        let keyCode = event.keyCode

        // 候補ウィンドウ表示中
        if candidateWindow.isVisible {
            switch keyCode {
            case 48 where event.modifierFlags.contains(.shift): // Shift+Tab
                candidateWindow.selectPrev()
                updateMarkedText(client: sender)
                return true
            case 48, 125: // Tab, ↓
                candidateWindow.selectNext()
                updateMarkedText(client: sender)
                return true
            case 126: // ↑
                candidateWindow.selectPrev()
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

        // 矢印キー等の特殊キーはスルー
        if keyCode >= 123 && keyCode <= 126 { return false }

        // 修飾キー付きはスルー
        let modifiers = event.modifierFlags
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return false }

        // 印字可能文字のみ受け付ける
        guard let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return false }

        pendingRomaji += chars
        let result = RomajiConverter.convert(pendingRomaji)
        composedHiragana += result.converted
        pendingRomaji = result.pending

        if composedHiragana.count >= 2 {
            refreshCandidates(client: sender)
        } else {
            candidateWindow.dismiss()
        }

        updateMarkedText(client: sender)
        return true
    }

    // MARK: - 確定

    override func commitComposition(_ sender: Any!) {
        guard !composingText.isEmpty else { return }
        let finalText = composedHiragana + RomajiConverter.forceFinalize(pendingRomaji)
        DatabaseManager.shared.record(input: finalText, output: finalText)
        commit(text: finalText, client: sender)
    }

    // MARK: - Private helpers

    private func refreshCandidates(client: Any?) {
        let result = DatabaseManager.shared.fetchCandidates(prefix: composedHiragana)
        var candidates = result.candidates
        // ひらがな自体を先頭候補として追加（重複除去）
        let hadHiragana = candidates.contains(composedHiragana)
        candidates.removeAll { $0 == composedHiragana }
        candidates.insert(composedHiragana, at: 0)
        // ひらがな挿入分 + 履歴件数（ひらがなが履歴にあった場合は重複除去済みなのでそのまま）
        let historyEnd = 1 + (hadHiragana ? result.historyCount - 1 : result.historyCount)
        currentCandidates = candidates
        if currentCandidates.isEmpty {
            candidateWindow.dismiss()
            return
        }

        // カーソル位置を取得
        var cursorRect = NSRect.zero
        if let c = client as? IMKTextInput {
            c.attributes(forCharacterIndex: 0, lineHeightRectangle: &cursorRect)
        }
        candidateWindow.show(candidates: currentCandidates, historySectionEnd: historyEnd, near: cursorRect)
    }

    private func confirmSelection(client: Any?) -> Bool {
        guard !composingText.isEmpty else { return false }
        let inputKey = composedHiragana + RomajiConverter.forceFinalize(pendingRomaji)
        if let selected = candidateWindow.selectedText() {
            DatabaseManager.shared.record(input: inputKey, output: selected)
            commit(text: selected, client: client)
        } else {
            commitComposition(client)
        }
        return true
    }

    private func displayText() -> String {
        if candidateWindow.isVisible, let selected = candidateWindow.selectedText() {
            return selected + pendingRomaji
        }
        return composingText
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
        composedHiragana = ""
        pendingRomaji = ""
        currentCandidates = []
        candidateWindow.dismiss()
    }

    private func handleBackspace(client: Any?) -> Bool {
        guard !composingText.isEmpty else { return false }
        if !pendingRomaji.isEmpty {
            pendingRomaji.removeLast()
        } else {
            composedHiragana.removeLast()
        }
        updateMarkedText(client: client)
        if composedHiragana.count >= 2 {
            refreshCandidates(client: client)
        } else {
            candidateWindow.dismiss()
        }
        return true
    }

    private func handleReturn(client: Any?) -> Bool {
        guard !composingText.isEmpty else { return false }
        commitComposition(client)
        return true
    }

    private func handleEscape(client: Any?) -> Bool {
        guard !composingText.isEmpty else { return false }
        composedHiragana = ""
        pendingRomaji = ""
        currentCandidates = []
        updateMarkedText(client: client)
        candidateWindow.dismiss()
        return true
    }
}

private extension NSRange {
    static let notFound = NSRange(location: NSNotFound, length: NSNotFound)
}
