import Cocoa
import InputMethodKit

@objc(InputController)
class InputController: IMKInputController {

    private var state = CompositionState()
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

    // MARK: - イベントハンドリング

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown else { return false }

        let keyCode = event.keyCode

        // 英数キー → 英字モードへ（未確定があれば確定）
        if keyCode == 102 {
            if !state.composingText.isEmpty { commitComposition(sender) }
            state.isAsciiMode = true
            return true
        }

        // かなキー → 日本語モードへ
        if keyCode == 104 {
            state.isAsciiMode = false
            return true
        }

        // 英字モード
        if state.isAsciiMode {
            // Escape → 日本語モードへ
            if keyCode == 53 { state.isAsciiMode = false; return true }
            let modifiers = event.modifierFlags
            guard modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
            guard let chars = event.characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return false }
            (sender as? IMKTextInput)?.insertText(chars, replacementRange: .notFound)
            return true
        }

        // 日本語モード: 候補ウィンドウ表示中
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
        let baseChars = event.charactersIgnoringModifiers ?? chars

        // Shift が押されていれば英字を直接挿入（未確定があれば先に確定）
        if CompositionState.isShiftInput(characters: chars, baseCharacters: baseChars) || modifiers.contains(.shift) {
            if !state.composingText.isEmpty { commitComposition(sender) }
            (sender as? IMKTextInput)?.insertText(chars, replacementRange: .notFound)
            return true
        }

        let needsRefresh = state.addRomaji(baseChars)
        if needsRefresh {
            refreshCandidates(client: sender)
        } else {
            candidateWindow.dismiss()
        }

        updateMarkedText(client: sender)
        return true
    }

    // MARK: - 確定

    override func commitComposition(_ sender: Any!) {
        guard !state.composingText.isEmpty else { return }
        let finalText = state.finalizedText
        DatabaseManager.shared.record(input: finalText, output: finalText)
        commit(text: finalText, client: sender)
    }

    // MARK: - Private helpers

    private func refreshCandidates(client: Any?) {
        let result = DatabaseManager.shared.fetchCandidates(prefix: state.composedHiragana)
        var candidates = result.candidates
        // ひらがな自体を先頭候補として追加（重複除去）
        let hadHiragana = candidates.contains(state.composedHiragana)
        candidates.removeAll { $0 == state.composedHiragana }
        candidates.insert(state.composedHiragana, at: 0)
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
        guard !state.composingText.isEmpty else { return false }
        let inputKey = state.finalizedText
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
            return selected + state.pendingRomaji
        }
        return state.composingText
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
        state = CompositionState()
        currentCandidates = []
        candidateWindow.dismiss()
    }

    private func handleBackspace(client: Any?) -> Bool {
        let (handled, needsRefresh) = state.backspace()
        guard handled else { return false }
        updateMarkedText(client: client)
        if needsRefresh {
            refreshCandidates(client: client)
        } else {
            candidateWindow.dismiss()
        }
        return true
    }

    private func handleReturn(client: Any?) -> Bool {
        guard !state.composingText.isEmpty else { return false }
        commitComposition(client)
        return true
    }

    private func handleEscape(client: Any?) -> Bool {
        guard state.reset() else { return false }
        updateMarkedText(client: client)
        candidateWindow.dismiss()
        return true
    }
}

private extension NSRange {
    static let notFound = NSRange(location: NSNotFound, length: NSNotFound)
}
