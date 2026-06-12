import Foundation

/// 候補テーブル 1 行分の表示状態（`CandidatePanelModel` から抽出）。
struct CandidateRowSnapshot: Equatable {
    let text: String
    let showsDelete: Bool
    let isHistory: Bool
    let sectionLabel: String
    let showsSectionDivider: Bool
}

/// `refreshInPlace` の差分判定用スナップショット。
struct CandidatePanelSnapshot: Equatable {
    let rows: [CandidateRowSnapshot]
    let selectedRow: Int

    init(rows: [CandidateRowSnapshot], selectedRow: Int) {
        self.rows = rows
        self.selectedRow = selectedRow
    }

    init(model: CandidatePanelModel) {
        selectedRow = model.selectedRow
        rows = model.candidates.indices.map { row in
            CandidateRowSnapshot(
                text: model.candidates[row],
                showsDelete: model.showsDeleteButton(at: row),
                isHistory: model.isHistoryRow(row),
                sectionLabel: model.sectionLabel(for: row),
                showsSectionDivider: model.showsSectionDivider(at: row)
            )
        }
    }
}

/// `NSTableView` への最小更新計画。
enum CandidateTablePatch: Equatable {
    case noop
    case reloadAll
    /// 先頭 `prefixLength` 行のテキストは一致。末尾を remove/insert し、必要なら prefix 行だけ reload。
    case incremental(
        prefixLength: Int,
        removeTailCount: Int,
        insertTailCount: Int,
        reloadPrefixRows: [Int]
    )
}

enum CandidateTablePatchPlanner {
    static func plan(old: CandidatePanelSnapshot?, new: CandidatePanelSnapshot) -> CandidateTablePatch {
        guard let old else { return .reloadAll }
        if old == new { return .noop }

        let oldTexts = old.rows.map(\.text)
        let newTexts = new.rows.map(\.text)

        if oldTexts == newTexts {
            let reloadRows = (0..<new.rows.count).filter { old.rows[$0] != new.rows[$0] }
            if reloadRows.isEmpty, old.selectedRow == new.selectedRow {
                return .noop
            }
            return .incremental(
                prefixLength: new.rows.count,
                removeTailCount: 0,
                insertTailCount: 0,
                reloadPrefixRows: reloadRows
            )
        }

        var prefix = 0
        while prefix < oldTexts.count, prefix < newTexts.count, oldTexts[prefix] == newTexts[prefix] {
            prefix += 1
        }
        if prefix == 0 { return .reloadAll }

        let reloadPrefixRows = (0..<prefix).filter { old.rows[$0] != new.rows[$0] }
        return .incremental(
            prefixLength: prefix,
            removeTailCount: oldTexts.count - prefix,
            insertTailCount: newTexts.count - prefix,
            reloadPrefixRows: reloadPrefixRows
        )
    }
}
