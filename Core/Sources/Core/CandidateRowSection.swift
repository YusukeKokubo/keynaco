import Foundation

/// 候補リスト内の行が属するセクション（描画・Debug JSON 共通）。
public enum CandidateRowSection: String, Equatable, Sendable {
    case fixed
    case history
    case dictionary
}

/// 候補行のセクション判定と UI メタデータ。`ScoredCandidate.Source` が正本。
public enum CandidateRowMetadata {

    public static func section(for source: ScoredCandidate.Source) -> CandidateRowSection {
        if CandidateScoreBuilder.isHiraganaPreferredSource(source) { return .fixed }
        if CandidateScoreBuilder.isHistorySource(source) { return .history }
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

    public static func isHistoryRow(
        row: Int,
        sources: [ScoredCandidate.Source]
    ) -> Bool {
        guard sources.indices.contains(row) else { return false }
        return isHistoryDeletable(source: sources[row])
    }

    public static func showsDeleteButton(
        row: Int,
        sources: [ScoredCandidate.Source]
    ) -> Bool {
        isHistoryRow(row: row, sources: sources)
    }

    public static func showsSectionDivider(
        row: Int,
        sources: [ScoredCandidate.Source]
    ) -> Bool {
        guard sources.indices.contains(row), row + 1 < sources.count else { return false }
        return section(for: sources[row]) != section(for: sources[row + 1])
    }

    /// 先頭から連続する hiragana preferred 行数（Zenzai 診断用）。
    public static func legacyFixedEnd(
        sources: [ScoredCandidate.Source]
    ) -> Int {
        var fixedEnd = 0
        while fixedEnd < sources.count,
              CandidateScoreBuilder.isHiraganaPreferredSource(sources[fixedEnd]) {
            fixedEnd += 1
        }
        return fixedEnd
    }
}
