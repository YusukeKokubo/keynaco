import AppKit

/// テキスト操作のクライアント（テキストエディタ側）を表すプロトコル。
/// IMKTextInput の薄い抽象。テストでは MockTextClient が実装する。
protocol TextInputClient: AnyObject {
    func insertText(_ text: String)
    func setMarkedText(_ text: String, selectionRange: NSRange)
    func setMarkedText(_ text: NSAttributedString, selectionRange: NSRange)
    func cursorRect() -> NSRect
}

extension TextInputClient {
    /// NSAttributedString 版のデフォルト実装（文字列版にフォールバック）
    func setMarkedText(_ text: NSAttributedString, selectionRange: NSRange) {
        setMarkedText(text.string, selectionRange: selectionRange)
    }
}
