import Foundation

public extension Notification.Name {
    /// Successor の N-gram 保留（`pendingSuccessorCandidates`）の有無が変わったときに送る。
    static let keynacoSuccessorPendingChanged = Notification.Name("keynacoSuccessorPendingChanged")
}
