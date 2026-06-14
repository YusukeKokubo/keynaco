import KeynacoCore

/// 候補パネルスピナー表示判定用。
enum AzooKeyFooterStatus: Equatable {
    case fetching

    /// Debug ソケット JSON 用。
    var rawValue: String { "fetching" }

    static func resolve(
        session: CandidateSession,
        isAzooKeyPending: Bool
    ) -> AzooKeyFooterStatus? {
        guard session.isVisible, !session.isBracketMode else { return nil }
        return isAzooKeyPending ? .fetching : nil
    }

    /// `hasPendingWork` または `pendingAzooKeyReading` が非 nil なら AzooKey 取得待ち。
    /// 非同期完了時に `pendingAzooKeyReading` をクリアすること（`InputController+AzooKeyAsync`）。
    static func isAzooKeyPending(pendingReading: String?, schedulerPending: Bool) -> Bool {
        schedulerPending || pendingReading != nil
    }
}
