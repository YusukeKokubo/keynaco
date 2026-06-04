import Cocoa
import KeynacoCore
import InputMethodKit

// MARK: - IMKTextInput → TextInputClient アダプタ

final class IMKTextInputAdapter: TextInputClient, @unchecked Sendable {
    private let client: IMKTextInput?
    private(set) var didInsertText = false
    #if DEBUG
    /// 直近の `setMarkedText` に渡したプレーンテキスト（IME サンドボックス用）。
    private(set) var lastMarkedText: String = ""
    #endif

    init(_ sender: Any?) {
        self.client = sender as? IMKTextInput
    }

    private(set) var lastInsertedText: String = ""

    func insertText(_ text: String) {
        didInsertText = true
        lastInsertedText = text
        // insertText は常に @MainActor の InputController 経由で呼ばれる
        #if DEBUG
        MainActor.assumeIsolated {
            NotificationCenter.default.post(
                name: .imeSandboxInsertText,
                object: nil,
                userInfo: ["text": text]
            )
        }
        #endif
        client?.insertText(text, replacementRange: .notFound)
    }

    func setMarkedText(_ text: String, selectionRange: NSRange) {
        #if DEBUG
        lastMarkedText = text
        #endif
        client?.setMarkedText(text, selectionRange: selectionRange, replacementRange: .notFound)
    }

    func setMarkedText(_ text: NSAttributedString, selectionRange: NSRange) {
        #if DEBUG
        lastMarkedText = text.string
        #endif
        client?.setMarkedText(text, selectionRange: selectionRange, replacementRange: .notFound)
    }

    func selectedRange() -> NSRange {
        client?.selectedRange() ?? NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ text: String, selectionRange: NSRange, replacementRange: NSRange) {
        #if DEBUG
        lastMarkedText = text
        #endif
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
        let prefixLength = sel.location - prefixStart
        var prefixActual = NSRange()
        let prefix = c.string(
            from: NSRange(location: prefixStart, length: prefixLength),
            actualRange: &prefixActual
        ) ?? ""

        let totalLength = c.length()
        var suffix = ""
        if totalLength != NSNotFound, totalLength >= sel.location + sel.length {
            let suffixStart = sel.location + sel.length
            let suffixLength = min(maxLength, totalLength - suffixStart)
            if suffixLength > 0 {
                var suffixActual = NSRange()
                suffix = c.string(
                    from: NSRange(location: suffixStart, length: suffixLength),
                    actualRange: &suffixActual
                ) ?? ""
            }
        }
        return (prefix, suffix)
    }
}

private extension NSRange {
    static let notFound = NSRange(location: NSNotFound, length: NSNotFound)
}
