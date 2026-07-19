import Foundation

/// whileTyping 非同期 fetch の結果。空配列 = abort の暗黙契約を廃止する。
public enum FetchRequestOutcome: Sendable, Equatable {
    /// ロック取得前に世代不一致で打ち切り。fetch 未実行。
    case abortedBeforeFetch
    /// fetch は走ったが到着時に世代不一致。結果は破棄（wasted 計上対象）。
    case wastedAfterFetch
    /// 世代一致のまま fetch 完了。
    case success([AzooKeyCandidate])

    public var didRunFetch: Bool {
        switch self {
        case .abortedBeforeFetch: false
        case .wastedAfterFetch, .success: true
        }
    }

    public var candidates: [AzooKeyCandidate] {
        switch self {
        case .abortedBeforeFetch, .wastedAfterFetch: []
        case .success(let candidates): candidates
        }
    }
}
