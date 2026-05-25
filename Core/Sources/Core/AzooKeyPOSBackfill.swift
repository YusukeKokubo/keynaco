import Foundation

public struct POSBackfillResult: Sendable, Equatable {
    public let classified: Int
    public let skipped: Int
    public let total: Int

    public init(classified: Int, skipped: Int, total: Int) {
        self.classified = classified
        self.skipped = skipped
        self.total = total
    }
}

/// 未分類 history を AzooKey 辞書で一括再分類する。
public enum AzooKeyPOSBackfill {
    nonisolated(unsafe) private static let sharedConverter = AzooKeyConverter()

    /// `limit` 省略時は未分類 output を全件処理する（1 パス）。
    public static func run(
        db: DatabaseManager = .shared,
        converter: AzooKeyConverting? = nil,
        limit: Int? = nil
    ) -> POSBackfillResult {
        let converter = converter ?? sharedConverter
        let entries = db.fetchUnclassifiedHistoryEntries(limit: limit)
        var classified = 0
        var skipped = 0
        for entry in entries {
            guard let c = AzooKeyPOSClassifier.classify(
                output: entry.output, reading: entry.reading, converter: converter
            ) else {
                skipped += 1
                continue
            }
            db.updatePOS(output: entry.output, pos: c.pos)
            classified += 1
        }
        return POSBackfillResult(classified: classified, skipped: skipped, total: entries.count)
    }
}
