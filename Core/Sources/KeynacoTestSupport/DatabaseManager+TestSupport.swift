@testable import KeynacoCore

extension DatabaseManager {
    /// テスト用: 削除済み `fetchHistoryExact` の Scored 版ラッパー。
    public func exactOutputs(reading: String) -> [String] {
        fetchHistoryExactScored(reading: reading).map(\.output)
    }

    /// テスト用: 削除済み `fetchHistoryPrefix` の merged 版ラッパー。
    public func mergedOutputs(reading: String) -> [String] {
        fetchHistoryScoredMerged(reading: reading).map(\.output)
    }
}
