#if DEBUG

import Foundation

public extension InputHandler {
    /// `candidateSession` を含むデバッグ用スナップショット。
    func snapshot(markedText: String) -> InputHandlerSnapshot {
        let session = candidateSession
        return InputHandlerSnapshot(
            composedHiragana: state.composedHiragana,
            pendingRomaji: state.pendingRomaji,
            composingText: state.composingText,
            markedText: markedText,
            isAsciiMode: isAsciiMode,
            isBracketMode: isBracketMode,
            isExplicitlySelected: session.isExplicitlySelected,
            candidateVisible: session.isVisible,
            selectedRow: session.selectedRow,
            selectedText: session.selectedText,
            fixedEnd: session.fixedEnd,
            candidates: session.candidates,
            committedHistory: Array(committedHistory.suffix(5)),
            sessionTextBuffer: sessionTextBuffer,
            candidateBuild: lastCandidateBuildDiagnostics
        )
    }
}

#endif
