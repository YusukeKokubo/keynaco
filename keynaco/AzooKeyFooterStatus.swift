import KeynacoCore

/// 候補パネル下部フッターに表示する AzooKey / Zenzai パイプライン状態。
enum AzooKeyFooterStatus: Equatable {
    case fetching
    case dictionary
    case zenzai

    var labelText: String {
        switch self {
        case .fetching: return "辞書取得中…"
        case .dictionary: return "辞書"
        case .zenzai: return "Zenzai"
        }
    }

    /// Debug ソケット JSON 用。
    var rawValue: String {
        switch self {
        case .fetching: return "fetching"
        case .dictionary: return "dictionary"
        case .zenzai: return "zenzai"
        }
    }

    static func resolve(
        session: CandidateSession,
        isAzooKeyPending: Bool,
        isZenzaiRankingActive: Bool
    ) -> AzooKeyFooterStatus? {
        guard session.isVisible, !session.isBracketMode else { return nil }
        if isAzooKeyPending { return .fetching }
        guard session.historyEnd < session.candidates.count else { return nil }
        return isZenzaiRankingActive ? .zenzai : .dictionary
    }

    /// `hasPendingWork` または `pendingAzooKeyReading` が非 nil なら AzooKey 取得待ち。
    /// 非同期完了時に `pendingAzooKeyReading` をクリアすること（`InputController+AzooKeyAsync`）。
    static func isAzooKeyPending(pendingReading: String?, schedulerPending: Bool) -> Bool {
        schedulerPending || pendingReading != nil
    }
}
