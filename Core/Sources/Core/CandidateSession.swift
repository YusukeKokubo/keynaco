import Foundation

/// 候補 UI の単一の正本。`InputHandler` が `CandidateAction` を返し、`InputController` が
/// `apply` 後に `CandidateWindow.present(session:)` で描画する。
public struct CandidateSession: Sendable, Equatable {

    public var candidates: [String] = []
    /// 論理表示中（`NSWindow.isVisible` とは別。候補パネルを出すべき状態）。
    public var isVisible = false
    public var selectedRow = 0
    public var isExplicitlySelected = false
    public var historyEnd = 0
    public var fixedEnd = 0
    public var zenzaiRow: Int? = nil
    /// 非 `nil` のとき括弧モード。候補リストはこの配列と同期する。
    public var bracketCandidates: [String]? = nil

    public var isBracketMode: Bool { bracketCandidates != nil }

    public var selectedText: String? {
        guard isVisible, candidates.indices.contains(selectedRow) else { return nil }
        return candidates[selectedRow]
    }

    public var context: CandidateContext {
        CandidateContext(
            isVisible: isVisible,
            selectedRow: selectedRow,
            selectedText: selectedText,
            isExplicitlySelected: isExplicitlySelected,
            historyEnd: historyEnd,
            fixedEnd: fixedEnd
        )
    }

    public init() {}

    public mutating func reset() {
        candidates = []
        isVisible = false
        selectedRow = 0
        isExplicitlySelected = false
        historyEnd = 0
        fixedEnd = 0
        zenzaiRow = nil
        bracketCandidates = nil
    }

    /// 削除ボタン（UI）から行を除去する。DB 削除は呼び出し側の責務。
    public mutating func removeCandidate(at row: Int) {
        guard candidates.indices.contains(row) else { return }
        candidates.remove(at: row)
        if row < historyEnd { historyEnd -= 1 }
        if candidates.isEmpty {
            reset()
        } else {
            selectedRow = min(selectedRow, candidates.count - 1)
        }
    }

    /// `InputHandler` / デバッグソケットが返した `CandidateAction` を反映する。
    public mutating func apply(_ action: CandidateAction) {
        switch action {
        case .none:
            break
        case .show(let cands, let he, let initial, let fe, let zRow):
            candidates = cands
            isVisible = !cands.isEmpty
            selectedRow = cands.isEmpty ? 0 : min(initial, cands.count - 1)
            historyEnd = he
            fixedEnd = fe
            zenzaiRow = zRow
            isExplicitlySelected = false
        case .dismiss:
            reset()
        case .selectNext:
            guard isVisible, !candidates.isEmpty else { break }
            selectedRow = (selectedRow + 1) % candidates.count
            isExplicitlySelected = true
        case .selectPrev:
            guard isVisible, !candidates.isEmpty else { break }
            selectedRow = (selectedRow - 1 + candidates.count) % candidates.count
            isExplicitlySelected = true
        case .deleteSelected:
            guard isVisible, candidates.indices.contains(selectedRow) else { break }
            let row = selectedRow
            candidates.remove(at: row)
            if row < historyEnd { historyEnd -= 1 }
            if candidates.isEmpty {
                reset()
            } else {
                selectedRow = min(selectedRow, candidates.count - 1)
            }
        case .replaceCandidates(let cands):
            candidates = cands
            isVisible = !cands.isEmpty
            selectedRow = 0
            isExplicitlySelected = false
            zenzaiRow = nil
        }
    }
}
