import XCTest
@testable import KeynacoCore

/// PLAN260710a POC ゲート: 実辞書で副詞・助詞付き語のセグメント構成を固定する。
/// 「特に」が `特`+`に`(末尾 joshi) の多セグメントなら、lcid 判定でも誤トリムが再発する。
final class ParticleTrimSegmentPOCTests: XCTestCase {

    private struct Case {
        let reading: String
        let expectedText: String
        /// D1 で trim してほしい（真の内容語+助詞）なら true。副詞一体なら false。
        let wantTrim: Bool
    }

    private let cases: [Case] = [
        // 副詞一体（文字列 trim だと誤爆していた語）→ 単一セグメント想定で trim しない
        Case(reading: "とくに", expectedText: "特に", wantTrim: false),
        Case(reading: "おもに", expectedText: "主に", wantTrim: false),
        Case(reading: "いっしょに", expectedText: "一緒に", wantTrim: false),
        // 「今は」は辞書見出し 1 セグメント（rcid だけ joshi）。count>=2 条件なら trim しない
        // → azooKey 確定では完成形 `いまは→今は` が育つ（D2 部分先行）
        Case(reading: "いまは", expectedText: "今は", wantTrim: false),
        // 真の内容語+助詞の多セグメント → trim する
        Case(reading: "とうきょうまで", expectedText: "東京まで", wantTrim: true),
    ]

    func testSegmentStructureForParticleTrimGate() {
        let converter = AzooKeyConverter()
        var failures: [String] = []

        for c in cases {
            _ = converter.requestCandidates(hiragana: c.reading, leftSideContext: nil, richCandidates: true)
            let texts = converter.requestCandidates(hiragana: c.reading, leftSideContext: nil, richCandidates: true).texts
            guard texts.contains(c.expectedText) else {
                failures.append("\(c.reading): 候補に「\(c.expectedText)」が無い: \(texts.prefix(12))")
                continue
            }
            guard let segments = converter.segmentSnapshots(for: c.reading, text: c.expectedText) else {
                failures.append("\(c.reading)/\(c.expectedText): セグメント取得失敗")
                continue
            }
            let wouldTrim = AzooKeyConverter.shouldTrimTrailingJoshi(segments: segments)
            let desc = segments.map(\.description).joined(separator: " | ")
            print("POC \(c.reading)→\(c.expectedText): count=\(segments.count) wouldTrim=\(wouldTrim) wantTrim=\(c.wantTrim) :: \(desc)")

            if wouldTrim != c.wantTrim {
                failures.append(
                    "\(c.reading)→\(c.expectedText): wouldTrim=\(wouldTrim) want=\(c.wantTrim) segments=[\(desc)]"
                )
            }
        }

        XCTAssertTrue(failures.isEmpty, "POC ゲート失敗:\n" + failures.joined(separator: "\n"))
    }
}
