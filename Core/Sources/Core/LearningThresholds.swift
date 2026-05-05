/// N-gram / Successor 判定で共有する閾値。
enum LearningThresholds {
    /// 直近窓内の bi-gram の MAX(count) がこの値以上なら Successor で即時表示（プリセット行の初期 count も同じ）。
    static let successorImmediateThreshold = 5
}
