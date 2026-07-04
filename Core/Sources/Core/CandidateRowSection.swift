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
    public static func fixedEnd(
        sources: [ScoredCandidate.Source]
    ) -> Int {
        var fixedEnd = 0
        while fixedEnd < sources.count,
              CandidateScoreBuilder.isHiraganaPreferredSource(sources[fixedEnd]) {
            fixedEnd += 1
        }
        return fixedEnd
    }

    /// デバッグ診断用 source ラベル（`historyExact` 等）。
    public static func diagnosticSourceLabel(for source: ScoredCandidate.Source) -> String {
        switch source {
        case .historyExact: return "historyExact"
        case .historyPrefix: return "historyPrefix"
        case .userDict(let exact): return exact ? "userDictExact" : "userDictPrefix"
        case .azooKey(let rank): return "azooKey(\(rank))"
        case .hiraganaPreferred: return "hiraganaPreferred"
        case .hiraganaBuiltin: return "hiraganaBuiltin"
        case .number: return "number"
        case .dateTime: return "dateTime"
        }
    }

    /// `"historyPrefix:情報共有(93.00)"` 形式のスコア付き source 要約。
    public static func scoredCandidateDiagnosticLabel(_ candidate: ScoredCandidate) -> String {
        let source = diagnosticSourceLabel(for: candidate.source)
        return "\(source):\(candidate.text)(\(String(format: "%.2f", candidate.score)))"
    }

    /// `CandidateDivergenceRecord.confirmedSource` 用（`dict` / `fixed` / `history`）。
    public static func divergenceConfirmedSource(for source: ScoredCandidate.Source) -> String {
        switch section(for: source) {
        case .fixed: return "fixed"
        case .history: return "history"
        case .dictionary: return "dict"
        }
    }
}
