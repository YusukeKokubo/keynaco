import Foundation

public extension Notification.Name {
    /// Successor の N-gram 保留（`pendingSuccessorCandidates`）の有無が変わったときに送る。
    public static let keynacoSuccessorPendingChanged = Notification.Name("keynacoSuccessorPendingChanged")
    /// 誤変換検出で LLM が指摘を返したとき。`userInfo["detail"]` に全文。
    public static let keynacoMisconversionIssueFound = Notification.Name("keynacoMisconversionIssueFound")
    /// 誤変換検出の指摘状態をクリアするとき（新しい組成開始・チェック結果 OK・サーバ非アクティブ化など）。
    public static let keynacoMisconversionCleared = Notification.Name("keynacoMisconversionCleared")
}
