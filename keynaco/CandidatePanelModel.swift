import Cocoa
import KeynacoCore

/// `CandidateSession` から導出する候補パネル描画用 view model。mutable 状態は持たない。
struct CandidatePanelModel: Equatable {
    let session: CandidateSession
    let azooKeyFooter: AzooKeyFooterStatus?

    init(session: CandidateSession, azooKeyFooter: AzooKeyFooterStatus? = nil) {
        self.session = session
        self.azooKeyFooter = azooKeyFooter
    }

    var candidates: [String] { session.candidates }
    var selectedRow: Int { session.selectedRow }
    var isExplicitlySelected: Bool { session.isExplicitlySelected }
    var fixedEnd: Int { session.fixedEnd }
    var candidateSources: [ScoredCandidate.Source] { session.candidateSources }
    var isPresented: Bool { session.isVisible && !session.candidates.isEmpty }

    /// 候補行に対応する Zenzai 内部順位（1 始まり）。Zenzai 非アクティブ時 / 該当行が AzooKey 候補でないときは nil。
    func zenzaiRank(for row: Int) -> Int? {
        guard !session.azooKeyApiOrder.isEmpty,
              session.candidates.indices.contains(row) else { return nil }
        let text = session.candidates[row]
        return session.azooKeyApiOrder.firstIndex(of: text).map { $0 + 1 }
    }

    func section(for row: Int) -> CandidateRowSection {
        CandidateRowMetadata.section(row: row, sources: candidateSources)
    }

    func showsDeleteButton(at row: Int) -> Bool {
        CandidateRowMetadata.showsDeleteButton(row: row, sources: candidateSources)
    }

    func isHistoryRow(_ row: Int) -> Bool {
        CandidateRowMetadata.isHistoryRow(row: row, sources: candidateSources)
    }

    func showsSectionDivider(at row: Int) -> Bool {
        CandidateRowMetadata.showsSectionDivider(row: row, sources: candidateSources)
    }

    /// 行右端のセクションラベル。セクション境界行のみ非空。
    func sectionLabel(for row: Int) -> String {
        guard showsSectionDivider(at: row) else { return "" }
        switch section(for: row + 1) {
        case .history: return "履歴"
        case .dictionary: return "辞書"
        default: return ""
        }
    }

    var selectedText: String? { session.selectedText }
}

/// 候補ウィンドウの更新種別。
enum CandidatePanelLayout: Equatable {
    case dismiss
    case refreshInPlace
    case selectionOnly
    case present(near: NSRect)
}
