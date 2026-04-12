import AppKit

/// テキスト操作のクライアント（テキストエディタ側）を表すプロトコル。
/// IMKTextInput の薄い抽象。テストでは MockTextClient が実装する。
protocol TextInputClient: AnyObject {
    func insertText(_ text: String)
    func setMarkedText(_ text: String, selectionRange: NSRange)
    func cursorRect() -> NSRect
}
