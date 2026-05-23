#if DEBUG

import Foundation

/// `InputController` が `InputHandler` と候補ウィンドウから組み立てるデバッグ用スナップショット。
public struct InputHandlerSnapshot: Sendable {
    public var composedHiragana: String
    public var pendingRomaji: String
    public var composingText: String
    public var markedText: String

    public var isAsciiMode: Bool
    public var isSegmentMode: Bool
    public var isBracketMode: Bool
    public var isExplicitlySelected: Bool

    public var candidateVisible: Bool
    public var selectedRow: Int
    public var selectedText: String?
    public var historyEnd: Int
    public var fixedEnd: Int
    public var candidates: [String]

    public var committedHistory: [String]

    public var segmentTexts: [String]
    public var focusedSegmentIndex: Int

    /// 組成なし Successor 候補ウィンドウ表示中（旧 `isSuccessorMode` の代替）。
    public var successorCandidateActive: Bool {
        candidateVisible && composedHiragana.isEmpty && !isBracketMode && !isSegmentMode
    }
}

#endif
