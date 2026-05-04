#if DEBUG

import Foundation

/// `InputController` が `InputHandler` と候補ウィンドウから組み立てるデバッグ用スナップショット。
struct InputHandlerSnapshot: Sendable {
    var composedHiragana: String
    var pendingRomaji: String
    var composingText: String
    var markedText: String

    var isAsciiMode: Bool
    var isSuccessorMode: Bool
    var isSegmentMode: Bool
    var isBracketMode: Bool
    var isExplicitlySelected: Bool

    var candidateVisible: Bool
    var selectedRow: Int
    var selectedText: String?
    var historyEnd: Int
    var fixedEnd: Int
    var candidates: [String]

    var committedHistory: [String]

    var segmentTexts: [String]
    var focusedSegmentIndex: Int
}

#endif
