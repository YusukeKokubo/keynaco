import Foundation

/// 打鍵中に前方一致履歴を読み完全一致履歴より先に出すかどうかの判定。
enum HistoryPrefixPromotion {
    /// merged スコアの最低値（`historyRecencyScoreCutoff` 0.5 より十分大きい領域）。
    static let minScore: Double = 20
    /// exact 最高スコアに対する倍率。
    static let scoreRatioOverExact: Double = 3

    static func qualifies(prefixScore: Double, bestExactScore: Double) -> Bool {
        guard prefixScore >= minScore else { return false }
        if bestExactScore <= 0 { return true }
        return prefixScore >= bestExactScore * scoreRatioOverExact
    }

    static func bestExactScore(
        exactMatchHighHistory: [String],
        exactMatchScores: [String: Double]
    ) -> Double {
        exactMatchHighHistory.compactMap { exactMatchScores[$0] }.max() ?? 0
    }

    /// `prefixHistory` の順序を保ち、昇格条件を満たす output だけ返す。
    static func promotedItems(
        prefixHistory: [String],
        prefixScores: [String: Double],
        bestExactScore: Double
    ) -> [String] {
        prefixHistory.filter { output in
            guard let score = prefixScores[output] else { return false }
            return qualifies(prefixScore: score, bestExactScore: bestExactScore)
        }
    }
}
