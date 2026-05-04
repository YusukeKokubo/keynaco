import AppKit
import InputMethodKit
import os

/// IMK クライアントから `attributedSubstring(from:)` / `length` でカーソル前後を取得する。
/// `attributedSubstring` / `length` / `selectedRange` は MainActor 上の IMK クライアント呼び出しのみで使うこと。
enum SurroundingIMKContext {
    private static let logger = Logger(subsystem: "com.yusuke.inputmethod.keynaco", category: "SurroundingIMK")

    /// - Returns: `sender` が `IMKTextInput` でない、または `selectedRange().location == NSNotFound` のときは `nil`。
    ///   それ以外は常に `(before, after)` を返す（`after` は長さ超え等で取れないとき空文字）。
    @MainActor
    static func fetch(from sender: Any?, maxUnits: Int = 300) -> (before: String, after: String)? {
        guard let client = sender as? IMKTextInput else { return nil }
        let range = client.selectedRange()
        guard range.location != NSNotFound else { return nil }

        let beforeLocation = max(0, range.location - maxUnits)
        let beforeLength = range.location - beforeLocation
        let beforeAttr = client.attributedSubstring(from: NSRange(location: beforeLocation, length: beforeLength))
        let before = beforeAttr?.string ?? ""

        let totalLength = client.length()
        var after = ""
        if totalLength != NSNotFound, totalLength >= range.location + range.length {
            let afterLocation = range.location + range.length
            let afterLength = min(maxUnits, totalLength - afterLocation)
            if afterLength > 0 {
                let afterAttr = client.attributedSubstring(from: NSRange(location: afterLocation, length: afterLength))
                after = afterAttr?.string ?? ""
            }
        }

        #if DEBUG
        logger.debug("beforeLen=\(before.count) afterLen=\(after.count) loc=\(range.location)")
        #endif

        return (before, after)
    }
}
