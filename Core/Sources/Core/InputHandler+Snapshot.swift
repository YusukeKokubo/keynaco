#if DEBUG

import Foundation

public extension InputHandler {
    /// 候補ウィンドウの状態は `InputController` が上書きする（ここではダミーで埋める）。
    func snapshot(markedText: String) -> InputHandlerSnapshot {
        InputHandlerSnapshot(
            composedHiragana: state.composedHiragana,
            pendingRomaji: state.pendingRomaji,
            composingText: state.composingText,
            markedText: markedText,
            isAsciiMode: Self.isAsciiMode,
            isBracketMode: isBracketMode,
            isExplicitlySelected: false,
            candidateVisible: false,
            selectedRow: 0,
            selectedText: nil,
            historyEnd: 0,
            fixedEnd: 0,
            candidates: [],
            committedHistory: Array(committedHistory.suffix(5)),
            sessionTextBuffer: sessionTextBuffer
        )
    }
}

#endif
