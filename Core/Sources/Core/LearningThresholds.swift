/// N-gram / Successor 判定で共有する閾値。
public enum LearningThresholds {
    /// プリセット bi-gram 行の初期 `count`（`DatabaseManager` seed）に使う。かつて Successor の即時表示閾値にも用いた。
    public static let successorImmediateThreshold = 5
    /// Successor モードで表示する最大候補数。
    public static let successorMaxCandidates = 5
}
