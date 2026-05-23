#if DEBUG

import Foundation
import KeynacoCore

// MARK: - DebugCandidateWindow

struct DebugCandidateWindow {
    var isVisible = false
    var candidates: [String] = []
    var selectedRow = 0
    var historyEnd = 0
    var predictionEnd = 0
    var fixedEnd = 0
    var isExplicitlySelected = false

    var selectedText: String? {
        guard isVisible, candidates.indices.contains(selectedRow) else { return nil }
        return candidates[selectedRow]
    }

    var context: CandidateContext {
        CandidateContext(
            isVisible: isVisible,
            selectedRow: selectedRow,
            selectedText: selectedText,
            isExplicitlySelected: isExplicitlySelected,
            historyEnd: historyEnd,
            fixedEnd: fixedEnd
        )
    }

    mutating func apply(action: CandidateAction) {
        switch action {
        case .none:
            break
        case .show(let cands, let he, let initial, let pe, let fe):
            candidates = cands
            isVisible = !cands.isEmpty
            selectedRow = cands.isEmpty ? 0 : min(initial, cands.count - 1)
            historyEnd = he; predictionEnd = pe; fixedEnd = fe; isExplicitlySelected = false
        case .dismiss:
            isVisible = false; candidates = []; selectedRow = 0; isExplicitlySelected = false
        case .selectNext:
            guard isVisible, !candidates.isEmpty else { break }
            selectedRow = min(selectedRow + 1, candidates.count - 1); isExplicitlySelected = true
        case .selectPrev:
            guard isVisible, !candidates.isEmpty else { break }
            selectedRow = max(selectedRow - 1, 0); isExplicitlySelected = true
        case .deleteSelected:
            guard isVisible, candidates.indices.contains(selectedRow) else { break }
            let row = selectedRow
            candidates.remove(at: row)
            if row < predictionEnd { predictionEnd -= 1 }
            if row < historyEnd    { historyEnd -= 1 }
            if candidates.isEmpty { isVisible = false; selectedRow = 0 }
            else { selectedRow = min(selectedRow, candidates.count - 1) }
        }
    }
}

#endif
