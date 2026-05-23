#if DEBUG

import Foundation

public extension InputHandler {
    /// 候補ウィンドウの状態は `InputController` が上書きする（ここではダミーで埋める）。
    func snapshot(markedText: String) -> InputHandlerSnapshot {
        let segTexts: [String]
        let segFocus: Int
        if let ss = state.segmentState {
            segTexts = ss.segments.map(\.selectedText)
            segFocus = ss.focusedIndex
        } else {
            segTexts = []
            segFocus = 0
        }
        return InputHandlerSnapshot(
            composedHiragana: state.composedHiragana,
            pendingRomaji: state.pendingRomaji,
            composingText: state.composingText,
            markedText: markedText,
            isAsciiMode: Self.isAsciiMode,
            isSegmentMode: state.isSegmentMode,
            isBracketMode: isBracketMode,
            isExplicitlySelected: false,
            candidateVisible: false,
            selectedRow: 0,
            selectedText: nil,
            historyEnd: 0,
            fixedEnd: 0,
            candidates: [],
            committedHistory: Array(committedHistory.suffix(5)),
            segmentTexts: segTexts,
            focusedSegmentIndex: segFocus
        )
    }
}

#endif
