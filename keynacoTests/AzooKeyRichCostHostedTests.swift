import XCTest
@testable import keynaco
import KeynacoCore

/// PLAN260704b C1: whileTyping 経路の `richCandidates: true` コスト POC（アプリバンドル + Zenzai 実機）。
final class AzooKeyRichCostHostedTests: XCTestCase {

    private static let plainWords: [String] = [
        "かんじ", "にほん", "とうきょう", "さくら", "なつ",
        "はる", "あき", "ふゆ", "かぜ", "みず",
        "つき", "ほし", "やま", "かわ", "うみ",
        "とり", "はな", "いぬ", "ねこ", "くるま",
    ]

    private static let richWords: [String] = [
        "あさひ", "ゆうひ", "しんぶん", "でんわ", "てがみ",
        "かばん", "えんぴつ", "じしょ", "びょういん", "えき",
        "こうえん", "びょうき", "りょこう", "しごと", "がっこう",
        "せんせい", "がくせい", "りんご", "みかん", "ぶどう",
    ]

    private static let leftContext = "日本語のテストです"

    func testWhileTypingRichVsPlain_costPOC() throws {
        guard Bundle.main.url(forResource: "ggml-model-Q5_K_M", withExtension: "gguf") != nil else {
            throw XCTSkip("Zenzai model not in app bundle")
        }
        let converter = ZenzaiSettings.makeConverter()
        guard converter.isZenzaiEnabled else {
            throw XCTSkip("Zenzai disabled in settings")
        }

        let limit = AzooKeyConverter.whileTypingInferenceLimit
        let typingOptions = AzooKeyFetchOptions(zenzaiInferenceLimit: limit)

        // モデル warm（計測対象外）
        _ = converter.requestCandidates(
            hiragana: "てすと",
            leftSideContext: Self.leftContext,
            richCandidates: false,
            options: typingOptions
        )

        let plain = measure(
            converter: converter,
            words: Self.plainWords,
            richCandidates: false,
            options: typingOptions
        )
        let rich = measure(
            converter: converter,
            words: Self.richWords,
            richCandidates: true,
            options: typingOptions
        )

        printStats(label: "C1 POC plain rich=false inference=\(limit)", durations: plain)
        printStats(label: "C1 POC rich rich=true inference=\(limit)", durations: rich)

        let plainP50 = percentile(plain, 50)
        let richP50 = percentile(rich, 50)
        let deltaPct = plainP50 > 0 ? (richP50 - plainP50) / plainP50 * 100 : 0
        print(String(format: "C1 POC: plain p50=%.1fms rich p50=%.1fms delta=%+.1f%%", plainP50, richP50, deltaPct))
        print("C1 POC threshold: adopt rich=false if delta >= 20%")

        // 計測専用。判断は POC ログと plan に記録する。
        XCTAssertFalse(plain.isEmpty)
        XCTAssertFalse(rich.isEmpty)
    }

    private func measure(
        converter: AzooKeyConverter,
        words: [String],
        richCandidates: Bool,
        options: AzooKeyFetchOptions
    ) -> [Double] {
        var durations: [Double] = []
        for word in words {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = converter.requestCandidates(
                hiragana: word,
                leftSideContext: Self.leftContext,
                richCandidates: richCandidates,
                options: options
            )
            durations.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        return durations
    }

    private func percentile(_ durations: [Double], _ p: Int) -> Double {
        let sorted = durations.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, sorted.count * p / 100)]
    }

    private func printStats(label: String, durations: [Double]) {
        let sorted = durations.sorted()
        let n = sorted.count
        guard n > 0 else { return }
        func pct(_ p: Int) -> Double { sorted[min(n - 1, n * p / 100)] }
        let mean = durations.reduce(0, +) / Double(n)
        print("")
        print("=== \(label) (n=\(n)) ===")
        print(String(format: "  mean=%.1fms  p50=%.1fms  p95=%.1fms  max=%.1fms",
                     mean, pct(50), pct(95), sorted.last!))
    }
}
