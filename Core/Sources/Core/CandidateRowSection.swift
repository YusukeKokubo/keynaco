import Foundation

/// 候補リスト内の行が属するセクション（描画・Debug JSON 共通）。
public enum CandidateRowSection: String, Equatable, Sendable {
    case fixed
    case history
    case dictionary
    case zenzai
}

/// 候補行のセクション判定と UI メタデータ。`CandidateSession` の `fixedEnd` / `historyEnd` / `zenzaiRow` を入力とする。
public enum CandidateRowMetadata {

    public static func section(
        row: Int,
        fixedEnd: Int,
        historyEnd: Int,
        zenzaiRow: Int?
    ) -> CandidateRowSection {
        if zenzaiRow == row { return .zenzai }
        if row < fixedEnd { return .fixed }
        if row < historyEnd { return .history }
        return .dictionary
    }

    /// `fixedEnd <= row < historyEnd` の履歴行（Shift+Delete / 削除ボタン対象）。
    public static func isHistoryRow(row: Int, fixedEnd: Int, historyEnd: Int) -> Bool {
        row >= fixedEnd && row < historyEnd
    }

    public static func showsDeleteButton(row: Int, fixedEnd: Int, historyEnd: Int) -> Bool {
        isHistoryRow(row: row, fixedEnd: fixedEnd, historyEnd: historyEnd)
    }

    /// 履歴ブロック末尾と辞書ブロックの境界に区切り線を出すか。
    public static func showsSectionDivider(row: Int, historyEnd: Int, candidateCount: Int) -> Bool {
        row == historyEnd - 1 && historyEnd < candidateCount
    }
}
