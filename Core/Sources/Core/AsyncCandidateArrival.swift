import Foundation

/// AzooKey 非同期候補到着時の適用可否判定と選択行保持。`InputController` / sandbox 共通。
public enum AsyncCandidateArrival {
    public struct ApplyContext: Sendable, Equatable {
        public let candidateGeneration: Int
        public let arrivalGeneration: Int
        public let reading: String
        public let composedHiragana: String
        public let isExplicitlySelected: Bool
        public let isComposing: Bool

        public init(
            candidateGeneration: Int,
            arrivalGeneration: Int,
            reading: String,
            composedHiragana: String,
            isExplicitlySelected: Bool,
            isComposing: Bool
        ) {
            self.candidateGeneration = candidateGeneration
            self.arrivalGeneration = arrivalGeneration
            self.reading = reading
            self.composedHiragana = composedHiragana
            self.isExplicitlySelected = isExplicitlySelected
            self.isComposing = isComposing
        }
    }

    /// generation / reading / explicit / composing の 4 条件を満たすときだけ非同期結果を適用する。
    public static func shouldApply(_ context: ApplyContext) -> Bool {
        guard context.candidateGeneration == context.arrivalGeneration else { return false }
        guard context.composedHiragana == context.reading else { return false }
        guard !context.isExplicitlySelected else { return false }
        guard context.isComposing else { return false }
        return true
    }

    public struct RowPreservationSnapshot: Sendable, Equatable {
        public let wasVisible: Bool
        public let previousSelectedRow: Int
        public let previousSelectedText: String?

        public init(wasVisible: Bool, previousSelectedRow: Int, previousSelectedText: String?) {
            self.wasVisible = wasVisible
            self.previousSelectedRow = previousSelectedRow
            self.previousSelectedText = previousSelectedText
        }
    }

    public static func rowPreservationSnapshot(from session: CandidateSession) -> RowPreservationSnapshot {
        RowPreservationSnapshot(
            wasVisible: session.isVisible,
            previousSelectedRow: session.selectedRow,
            previousSelectedText: session.selectedText
        )
    }

    /// 非同期 `.show` で row 0 に戻されても、前回選択テキストが同じ行に残っていれば row を復元する。
    public static func applyCandidateAction(
        session: inout CandidateSession,
        action: CandidateAction,
        preservation: RowPreservationSnapshot
    ) {
        session.apply(action)
        guard preservation.wasVisible,
              !session.isExplicitlySelected,
              let text = preservation.previousSelectedText,
              preservation.previousSelectedRow < session.candidates.count,
              session.candidates[preservation.previousSelectedRow] == text else { return }
        session.selectedRow = preservation.previousSelectedRow
    }
}
