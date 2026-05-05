import AppKit
import InputMethodKit
import XCTest
@testable import keynaco

/// `IMKTextInput` は ObjC プロトコルのため NSObject サブクラスで準拠する。
@objc(MockIMKTextInputForSurrounding)
private final class MockIMKTextInputForSurrounding: NSObject, IMKTextInput {

    var stubSelectedRange = NSRange(location: 0, length: 0)
    var stubLength = 0
    /// UTF-16 インデックスごとの文字（簡易バッファ）。`attributedSubstring` はここから切り出す。
    var documentUTF16: [unichar] = []

    private func utf16String(from range: NSRange) -> String {
        guard range.location != NSNotFound, range.length >= 0 else { return "" }
        let end = range.location + range.length
        guard range.location >= 0, end <= documentUTF16.count else { return "" }
        return String(utf16CodeUnits: Array(documentUTF16[range.location..<end]), count: range.length)
    }

    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        NSAttributedString(string: utf16String(from: range))
    }

    func length() -> Int { stubLength }

    func selectedRange() -> NSRange { stubSelectedRange }

    // MARK: - IMKTextInput 未使用スタブ

    func insertText(_ string: Any!, replacementRange: NSRange) {}
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func validAttributesForMarkedText() -> [Any]? { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer!) -> NSAttributedString! { nil }
    func characterIndex(for point: NSPoint, tracking mode: IMKLocationToOffsetMappingMode, inMarkedRange partialFraction: UnsafeMutablePointer<ObjCBool>?) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>?) -> [AnyHashable: Any]? { nil }
    func baselineDelta(forCharacterAt anIndex: Int) -> CGFloat { 0 }
    func windowLevel() -> CGWindowLevel { 0 }
    func drawsVertically() -> Bool { false }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String?) {}
    func selectMode(_ modeIdentifier: String?) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String? { nil }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String? { nil }
    func string(from range: NSRange, actualRange: NSRangePointer?) -> String? { utf16String(from: range) }
}

@MainActor
final class SurroundingIMKContextTests: XCTestCase {

    func testSelectedRangeNotFoundReturnsNil() {
        let mock = MockIMKTextInputForSurrounding()
        mock.stubSelectedRange = NSRange(location: NSNotFound, length: 0)
        XCTAssertNil(SurroundingIMKContext.fetch(from: mock))
    }

    func testLocationZeroBeforeEmpty() {
        let mock = MockIMKTextInputForSurrounding()
        mock.documentUTF16 = Array("ab".utf16)
        mock.stubLength = mock.documentUTF16.count
        mock.stubSelectedRange = NSRange(location: 0, length: 0)
        let r = SurroundingIMKContext.fetch(from: mock)!
        XCTAssertEqual(r.before, "")
        XCTAssertEqual(r.after, "ab")
    }

    func testLocationLessThanMaxBeforeUsesActualLength() {
        let mock = MockIMKTextInputForSurrounding()
        mock.documentUTF16 = Array("abcdef".utf16)
        mock.stubLength = mock.documentUTF16.count
        mock.stubSelectedRange = NSRange(location: 2, length: 0)
        let r = SurroundingIMKContext.fetch(from: mock, maxUnits: 300)!
        XCTAssertEqual(r.before, "ab")
        XCTAssertEqual(r.after, "cdef")
    }

    func testTotalLengthNotFoundAfterEmptyBeforeStillReturned() {
        let mock = MockIMKTextInputForSurrounding()
        mock.documentUTF16 = Array("xy".utf16)
        mock.stubLength = NSNotFound
        mock.stubSelectedRange = NSRange(location: 1, length: 0)
        let r = SurroundingIMKContext.fetch(from: mock)!
        XCTAssertEqual(r.before, "x")
        XCTAssertEqual(r.after, "")
    }

    func testCursorAtDocumentEndAfterEmpty() {
        let mock = MockIMKTextInputForSurrounding()
        mock.documentUTF16 = Array("end".utf16)
        mock.stubLength = mock.documentUTF16.count
        mock.stubSelectedRange = NSRange(location: 3, length: 0)
        let r = SurroundingIMKContext.fetch(from: mock)!
        XCTAssertEqual(r.before, "end")
        XCTAssertEqual(r.after, "")
    }

    func testNormalCaseBeforeAndAfter() {
        let mock = MockIMKTextInputForSurrounding()
        let s = String(repeating: "a", count: 400) + "CURSOR" + String(repeating: "b", count: 400)
        mock.documentUTF16 = Array(s.utf16)
        mock.stubLength = mock.documentUTF16.count
        let cur = (String(repeating: "a", count: 400) as NSString).length
        mock.stubSelectedRange = NSRange(location: cur, length: 0)
        let r = SurroundingIMKContext.fetch(from: mock, maxUnits: 300)!
        XCTAssertEqual(r.before.count, 300)
        XCTAssertEqual(r.after.count, 300)
    }
}
