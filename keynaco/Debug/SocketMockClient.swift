#if DEBUG

import Foundation
import KeynacoCore
import InputMethodKit

// MARK: - SocketMockClient

/// SurroundingIMKContext.fetch() が IMKTextInput にキャストできるよう NSObject + IMKTextInput に準拠させる。
/// documentBefore / documentAfter で「カーソル前後のテキスト」を模倣し、
/// {"set_surrounding": {"before": "...", "after": "..."}} で外部から設定できる。
final class SocketMockClient: NSObject, TextInputClient, IMKTextInput, @unchecked Sendable {
    private var insertedTexts: [String] = []
    private(set) var markedText: String = ""

    /// カーソル前の確定済みテキスト（insertText で追記される）
    var documentBefore: String = ""
    /// カーソル後のテキスト（set_surrounding コマンドで設定。insertText では変化しない）
    var documentAfter: String = ""

    // MARK: TextInputClient

    func insertText(_ text: String) {
        insertedTexts.append(text)
        documentBefore += text
        markedText = ""
    }
    func setMarkedText(_ text: String, selectionRange: NSRange) { markedText = text }
    func cursorRect() -> NSRect { .zero }

    var hasPendingInsertions: Bool { !insertedTexts.isEmpty }

    func consume() -> [String] { let r = insertedTexts; insertedTexts = []; return r }
    func reset() { insertedTexts = []; markedText = ""; documentBefore = ""; documentAfter = "" }

    /// 確定直後 Backspace（`penalizeAll`）でアプリ側が削除するテキストを模倣する。
    func removeDocumentSuffix(_ text: String) {
        guard !text.isEmpty, documentBefore.hasSuffix(text) else { return }
        documentBefore.removeLast(text.count)
    }

    /// IME が Backspace を消費しなかったとき、アプリが 1 文字削除する挙動を模倣する。
    func removeLastDocumentCharacter() {
        guard !documentBefore.isEmpty else { return }
        documentBefore.removeLast()
    }

    // MARK: IMKTextInput — SurroundingIMKContext が使うメソッド

    func selectedRange() -> NSRange {
        NSRange(location: documentBefore.utf16.count, length: 0)
    }

    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        let full = documentBefore + documentAfter
        let utf16 = full.utf16
        guard range.location != NSNotFound,
              range.location >= 0,
              range.location + range.length <= utf16.count else { return nil }
        let si = utf16.index(utf16.startIndex, offsetBy: range.location)
        let ei = utf16.index(si, offsetBy: range.length)
        return NSAttributedString(string: String(utf16[si..<ei])!)
    }

    func length() -> Int { (documentBefore + documentAfter).utf16.count }

    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        attributedSubstring(from: range)?.string
    }

    // MARK: IMKTextInput — スタブ

    func insertText(_ string: Any!, replacementRange: NSRange) {}
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {}
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { NSNotFound }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { nil }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { nil }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { nil }
}

#endif
