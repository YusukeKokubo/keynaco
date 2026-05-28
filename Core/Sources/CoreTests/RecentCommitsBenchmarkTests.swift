import XCTest
@testable import KeynacoCore

/// 1 モーラサジェスト POC のパフォーマンス計測（observation.md）。
/// 50/20 という現状値を含む複数サイズで `recentCommitsMatching` と `appendRecentCommit` の
/// per-call 時間を計測し、件数を増やしたときの体感影響範囲を把握する。
/// 計測は CFAbsoluteTimeGetCurrent ベース。XCTMeasure ではなく手書きで複数サイズを 1 テストで網羅する。
final class RecentCommitsBenchmarkTests: XCTestCase {

    func makeHandler() -> InputHandler {
        InputHandler(db: DatabaseManager(inMemory: true))
    }

    func populate(_ handler: inout InputHandler, count: Int, readingHead: String = "あ") {
        // 上限を超えた場合は appendRecentCommit が古いものを捨てる挙動も込みで計測される。
        for i in 0..<count {
            handler.appendRecentCommit(reading: "\(readingHead)\(i)", output: "Out\(i)")
        }
    }

    func benchmark(label: String, iterations: Int = 100_000, body: () -> Void) -> Double {
        // warmup
        for _ in 0..<min(1_000, iterations / 10) { body() }
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations { body() }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perCallNs = (elapsed / Double(iterations)) * 1_000_000_000
        print("[BENCH] \(label): \(String(format: "%.1f", perCallNs)) ns/call (n=\(iterations))")
        return perCallNs
    }

    /// `recentCommitsMatching` の linear scan コストをプール件数を変えて計測。
    /// プレフィックスは 1 ひらがな（1 モーラサジェストの実シナリオ）。
    func testMatchingScalesLinearly() {
        // recentCommits は static cap=50 で append 時に切り捨てる。直接フィールドに代入できないので
        // テストは frequentCommits を使って「サイズ自由」にする。両方とも同じ linear scan 構造。
        // 形式: あ0, あ1, ..., あN-1 → "あ" prefix で全件マッチ（worst case）
        var results: [Int: Double] = [:]
        for size in [10, 50, 100, 500, 1_000, 5_000] {
            var handler = makeHandler()
            let entries = (0..<size).map { RecentCommit(reading: "あ\($0)", output: "Out\($0)") }
            handler.frequentCommits = entries
            let ns = benchmark(label: "match size=\(size) worst (all match)") {
                _ = handler.recentCommitsMatching(prefix: "あ")
            }
            results[size] = ns
        }
        XCTAssertGreaterThan(results[5_000]!, results[10]!, "件数増で時間は増えるはず")
    }

    /// 実シナリオに近い: プレフィックスは 1 char、マッチするのはごく少数（0〜数件）。
    func testMatchingRealisticHitRate() {
        for size in [10, 50, 100, 500, 1_000, 5_000] {
            var handler = makeHandler()
            // reading は あ/い/う/え/お/か/き/... を round-robin。「ぴ」prefix なら 0 件ヒット。
            let kanas = ["あ", "い", "う", "え", "お", "か", "き", "く", "け", "こ",
                         "さ", "し", "す", "せ", "そ", "た", "ち", "つ", "て", "と"]
            let entries = (0..<size).map { i in
                RecentCommit(reading: "\(kanas[i % kanas.count])おう\(i)", output: "Out\(i)")
            }
            handler.frequentCommits = entries
            _ = benchmark(label: "match size=\(size) realistic (~5% hit)") {
                _ = handler.recentCommitsMatching(prefix: "あ")
            }
        }
    }

    /// `appendRecentCommit` の cost を計測。cap 到達後は removeFirst が走る点に注意。
    func testAppendScalesAtCap() {
        // 上限ぴったりまで埋めてから連続 append を計測
        for cap in [50, 100, 500, 1_000] {
            var handler = makeHandler()
            // 上限値はテスト中変更できない（static let）なので、recentCommits を直接編集して
            // cap 相当の状態を作る。実装上は append → if count > cap { removeFirst }。
            // この計測は append + (count > 50 で removeFirst 発火) のシナリオ。
            handler.recentCommits = (0..<cap).map { RecentCommit(reading: "あ\($0)", output: "Out\($0)") }
            var i = 0
            _ = benchmark(label: "append cap=\(cap) (steady state)") {
                handler.appendRecentCommit(reading: "あn\(i)", output: "OutN\(i)")
                i += 1
            }
        }
    }
}
