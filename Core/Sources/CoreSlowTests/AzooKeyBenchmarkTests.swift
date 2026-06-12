import XCTest
@testable import KeynacoCore

/// AzooKey requestCandidates のレイテンシ計測テスト（Phase 0 判断用）。
///
/// 実機 AzooKey を直列で使うため `KeynacoCoreSlowTests` に置く（fast 並列実行と競合しない）。
/// `swift test -c release --filter AzooKeyBenchmarkTests` で Release 最適化ビルドで実行する。
/// テスト結果は XCTFail にはならず、標準出力に統計を出力する。
/// 判断基準: p95 が 16ms 以下 → 現状維持（案 C）、超える → Phase 1 へ進む。
final class AzooKeyBenchmarkTests: XCTestCase {

    func test_requestCandidates_coldMiss_latency() {
        let converter = AzooKeyConverter(zenzaiEnabled: false)

        // 異なる読みを使ってキャッシュミスを強制する
        let words: [String] = [
            "かんじ", "にほん", "とうきょう", "さくら", "なつ",
            "はる", "あき", "ふゆ", "かぜ", "みず",
            "つき", "ほし", "やま", "かわ", "うみ",
            "とり", "はな", "いぬ", "ねこ", "くるま",
        ]

        var durations: [Double] = []
        for word in words {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = converter.requestCandidates(hiragana: word, leftSideContext: nil)
            let dtMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            durations.append(dtMs)
        }

        printStats(label: "Zenzai=off, no context (cold miss)", durations: durations)
    }

    func test_requestCandidates_withLeftContext_latency() {
        let converter = AzooKeyConverter(zenzaiEnabled: false)
        let ctx = "日本語のテストです"

        let words: [String] = [
            "かんじ", "にほん", "とうきょう", "さくら", "なつ",
            "はる", "あき", "ふゆ", "かぜ", "みず",
            "つき", "ほし", "やま", "かわ", "うみ",
            "とり", "はな", "いぬ", "ねこ", "くるま",
        ]

        var durations: [Double] = []
        for word in words {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = converter.requestCandidates(hiragana: word, leftSideContext: ctx)
            let dtMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            durations.append(dtMs)
        }

        printStats(label: "Zenzai=off, left context (cold miss)", durations: durations)
    }

    func test_requestCandidates_cacheHit_latency() {
        let converter = AzooKeyConverter(zenzaiEnabled: false)

        // 1回目でキャッシュを温める
        let word = "かんじ"
        _ = converter.requestCandidates(hiragana: word, leftSideContext: nil)

        // 2回目以降はキャッシュヒット
        var durations: [Double] = []
        for _ in 0..<100 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = converter.requestCandidates(hiragana: word, leftSideContext: nil)
            let dtMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            durations.append(dtMs)
        }

        printStats(label: "cache hit (100 reps)", durations: durations)
    }

    // MARK: - helpers

    private func printStats(label: String, durations: [Double]) {
        guard !durations.isEmpty else {
            print("[\(label)] no data")
            return
        }
        let sorted = durations.sorted()
        let n = sorted.count
        func pct(_ p: Int) -> Double { sorted[min(n-1, n*p/100)] }
        let mean = durations.reduce(0, +) / Double(n)

        print("")
        print("=== \(label) (n=\(n)) ===")
        print(String(format: "  mean=%.1fms  p50=%.1fms  p95=%.1fms  p99=%.1fms  max=%.1fms",
                     mean, pct(50), pct(95), pct(99), sorted.last!))
        print(String(format: "  → p95 exceeds 16ms: %@", pct(95) > 16.0 ? "YES (Phase 1 needed)" : "NO (acceptable)"))
        print("  raw: \(sorted.map { String(format: "%.1f", $0) }.joined(separator: ", "))")

        // XCTestMeasurement として記録（Xcode のグラフにも残る）
        // p95 が 16ms を超えたら fail はしない（計測専用テスト）
    }
}
