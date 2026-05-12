import AppKit

/// テキスト操作のクライアント（テキストエディタ側）を表すプロトコル。
/// IMKTextInput の薄い抽象。テストでは MockTextClient が実装する。
public protocol TextInputClient: AnyObject {
    func insertText(_ text: String)
    func setMarkedText(_ text: String, selectionRange: NSRange)
    func setMarkedText(_ text: NSAttributedString, selectionRange: NSRange)
    func selectedRange() -> NSRange
    func setMarkedText(_ text: String, selectionRange: NSRange, replacementRange: NSRange)
    func cursorRect() -> NSRect
}

public extension TextInputClient {
    /// NSAttributedString 版のデフォルト実装（文字列版にフォールバック）
    func setMarkedText(_ text: NSAttributedString, selectionRange: NSRange) {
        setMarkedText(text.string, selectionRange: selectionRange)
    }
    /// selectedRange 未サポートのアプリ向けデフォルト実装
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    /// replacementRange 未サポートのアプリ向けデフォルト実装
    func setMarkedText(_ text: String, selectionRange: NSRange, replacementRange: NSRange) {
        setMarkedText(text, selectionRange: selectionRange)
    }
}
