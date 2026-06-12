import XCTest
@testable import KeynacoCore

/// AzooKey requestCandidates のレイテンシ計測テスト（Phase 0 判断用）。
///
/// 実機 AzooKey を直列で使うため `KeynacoCoreSlowTests` に置く（fast 並列実行と競合しない）。
/// `swift test -c release --filter AzooKeyBenchmarkTests` で Release 最適化ビルドで実行する。
/// テスト結果は XCTFail にはならず、標準出力に統計を出力する。
/// 判断基準: p95 が 16ms 以下 → 現状維持（案 C）、超える → Phase 1 へ進む。
/// Phase 3: rich=true 系を追加し Space 先読みのコスト判断に使う。
final class AzooKeyBenchmarkTests: XCTestCase {

    private static let benchmarkWords: [String] = [
        "かんじ", "にほん", "とうきょう", "さくら", "なつ",
        "はる", "あき", "ふゆ", "かぜ", "みず",
        "つき", "ほし", "やま", "かわ", "うみ",
        "とり", "はな", "いぬ", "ねこ", "くるま",
    ]

    private static let leftContext = "日本語のテストです"

    func test_requestCandidates_coldMiss_latency() {
        measureColdMiss(
            label: "Zenzai=off, rich=false, no context (cold miss)",
            zenzaiEnabled: false,
            leftContext: nil,
            richCandidates: false
        )
    }

    func test_requestCandidates_withLeftContext_latency() {
        measureColdMiss(
            label: "Zenzai=off, rich=false, left context (cold miss)",
            zenzaiEnabled: false,
            leftContext: Self.leftContext,
            richCandidates: false
        )
    }

    func test_requestCandidates_richTrue_coldMiss_latency() {
        measureColdMiss(
            label: "Zenzai=off, rich=true, no context (cold miss)",
            zenzaiEnabled: false,
            leftContext: nil,
            richCandidates: true
        )
    }

    func test_requestCandidates_richTrue_withLeftContext_latency() {
        measureColdMiss(
            label: "Zenzai=off, rich=true, left context (cold miss)",
            zenzaiEnabled: false,
            leftContext: Self.leftContext,
            richCandidates: true
        )
    }

    func test_requestCandidates_richTrue_zenzaiOn_latency() throws {
        guard Bundle.main.url(forResource: "ggml-model-Q5_K_M", withExtension: "gguf") != nil else {
            throw XCTSkip("Zenzai model not in test bundle")
        }
        let converter = AzooKeyConverter(zenzaiEnabled: true)
        // モデル warm
        _ = converter.requestCandidates(
            hiragana: "かんじ",
            leftSideContext: Self.leftContext,
            richCandidates: true
        )
        measureColdMiss(
            label: "Zenzai=on, rich=true, left context (cold miss, model warm)",
            converter: converter,
            leftContext: Self.leftContext,
            richCandidates: true
        )
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

    private func measureColdMiss(
        label: String,
        zenzaiEnabled: Bool = false,
        converter: AzooKeyConverter? = nil,
        leftContext: String?,
        richCandidates: Bool
    ) {
        let conv = converter ?? AzooKeyConverter(zenzaiEnabled: zenzaiEnabled)
        var durations: [Double] = []
        for word in Self.benchmarkWords {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = conv.requestCandidates(
                hiragana: word,
                leftSideContext: leftContext,
                richCandidates: richCandidates
            )
            let dtMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            durations.append(dtMs)
        }
        printStats(label: label, durations: durations)
    }

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
