import Foundation

/// 候補リスト内の行が属するセクション（描画・Debug JSON 共通）。
public enum CandidateRowSection: String, Equatable, Sendable {
    case fixed
    case history
    case dictionary
}

/// 候補行のセクション判定と UI メタデータ。
public enum CandidateRowMetadata {

    public static func section(for source: ScoredCandidate.Source) -> CandidateRowSection {
        if CandidateScoreBuilder.isHiraganaPreferredSource(source) { return .fixed }
        if CandidateScoreBuilder.isHistorySource(source) { return .history }
        return .dictionary
    }

    public static func section(
        row: Int,
        fixedEnd: Int,
        historyEnd: Int
    ) -> CandidateRowSection {
        if row < fixedEnd { return .fixed }
        if row < historyEnd { return .history }
        return .dictionary
    }

    public static func section(
        row: Int,
        sources: [ScoredCandidate.Source]
    ) -> CandidateRowSection {
        guard sources.indices.contains(row) else { return .dictionary }
        return section(for: sources[row])
    }

    public static func isHistoryDeletable(source: ScoredCandidate.Source) -> Bool {
        CandidateScoreBuilder.isHistorySource(source)
    }

    /// `fixedEnd <= row < historyEnd` の履歴行（レガシー連続ブロック用）。
    public static func isHistoryRow(row: Int, fixedEnd: Int, historyEnd: Int) -> Bool {
        row >= fixedEnd && row < historyEnd
    }

    public static func isHistoryRow(
        row: Int,
        sources: [ScoredCandidate.Source]
    ) -> Bool {
        guard sources.indices.contains(row) else { return false }
        return isHistoryDeletable(source: sources[row])
    }

    public static func showsDeleteButton(row: Int, fixedEnd: Int, historyEnd: Int) -> Bool {
        isHistoryRow(row: row, fixedEnd: fixedEnd, historyEnd: historyEnd)
    }

    public static func showsDeleteButton(
        row: Int,
        sources: [ScoredCandidate.Source]
    ) -> Bool {
        isHistoryRow(row: row, sources: sources)
    }

    /// 履歴ブロック末尾と辞書ブロックの境界に区切り線を出すか（レガシー連続ブロック用）。
    public static func showsSectionDivider(row: Int, historyEnd: Int, candidateCount: Int) -> Bool {
        row == historyEnd - 1 && historyEnd < candidateCount
    }

    public static func showsSectionDivider(
        row: Int,
        sources: [ScoredCandidate.Source]
    ) -> Bool {
        guard sources.indices.contains(row), row + 1 < sources.count else { return false }
        return section(for: sources[row]) != section(for: sources[row + 1])
    }

    /// 先頭から連続する fixed / history 行数（sandbox・診断の後方互換）。
    public static func legacyBoundaries(
        sources: [ScoredCandidate.Source]
    ) -> (fixedEnd: Int, historyEnd: Int) {
        var fixedEnd = 0
        while fixedEnd < sources.count,
              CandidateScoreBuilder.isHiraganaPreferredSource(sources[fixedEnd]) {
            fixedEnd += 1
        }
        var historyEnd = fixedEnd
        while historyEnd < sources.count,
              CandidateScoreBuilder.isHistorySource(sources[historyEnd]) {
            historyEnd += 1
        }
        return (fixedEnd, historyEnd)
    }
}
