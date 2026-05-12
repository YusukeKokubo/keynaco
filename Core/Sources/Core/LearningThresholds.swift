/// N-gram / Successor 判定で共有する閾値。
public enum LearningThresholds {
    /// 直近窓内の bi-gram の MAX(count) がこの値以上なら Successor で即時表示（プリセット行の初期 count も同じ）。
    public static let successorImmediateThreshold = 5
    /// Successor モードで表示する最大候補数。
    public static let successorMaxCandidates = 5
}
