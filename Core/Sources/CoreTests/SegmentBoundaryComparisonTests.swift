import XCTest
@testable import KeynacoCore

/// AzooKey 寄せ検討用: エンジン単体と InputHandler（ソケットなし）の境界比較
final class SegmentBoundaryComparisonTests: InputHandlerTestCase {

    private let engine = AzooKeyConverter()

    private struct EngineRow {
        let partial: String?
        let defaultEnd: Int
        let segmentize: String
        let strip: Int?
    }

    private func engineRow(for reading: String) -> EngineRow {
        let raw = engine.requestConversionResult(
            hiragana: reading,
            leftSideContext: nil,
            richCandidates: true
        )
        let partial = raw.firstClauseResults.first {
            !AzooKeyCandidateMerge.consumesWholeTarget($0.inputLength, convertTarget: reading)
        }
        let segFirst = engine.segmentize(reading, leftSideContext: nil).first?.reading
        let end = AzooKeyCandidateMerge.defaultClauseEnd(
            result: raw,
            convertTarget: reading,
            segmentizeFirstReading: segFirst
        )
        return EngineRow(
            partial: partial.map { "\($0.text):\($0.inputLength)" },
            defaultEnd: end,
            segmentize: engine.segmentize(reading, leftSideContext: nil).map(\.reading).joined(separator: "|"),
            strip: AzooKeyCandidateMerge.clauseEndStrippingTrailingParticle(reading)
        )
    }

    private func imeAfterSpace(romaji: String) -> (
        segMode: Bool,
        clauseEnd: Int?,
        selected: String?,
        segments: [String],
        cands: [String],
        remaining: String?
    ) {
        typeRomaji(romaji)
        let (_, action) = press(keyCode: 49)
        let cands: [String]
        if case .show(let list, _, _, _, _) = action { cands = Array(list.prefix(8)) }
        else { cands = [] }
        let ss = handler.state.segmentState
        return (
            handler.state.isSegmentMode,
            ss?.effectiveClauseEnd,
            ss?.current.selectedText,
            ss.map { $0.snapshotSegmentTexts } ?? [],
            cands,
            ss?.remainingReading
        )
    }

    func testPrintComparisonMatrix() {
        let cases: [(id: String, romaji: String, reading: String)] = [
            ("1_anataha", "anataha", "あなたは"),
            ("2_gakuseidesu", "gakuseidesu", "がくせいです"),
            ("3_watashihagakusei", "watashihagakusei", "わたしはがくせい"),
            ("4_konnitiha", "konnitiha", "こんにちは"),
            ("5_gakusei", "gakusei", "がくせい"),
            ("6_ryuugakuseidesu", "ryuugakuseidesu", "りゅうがくせいです"),
        ]
        for c in cases {
            setUp()
            let e = engineRow(for: c.reading)
            let i = imeAfterSpace(romaji: c.romaji)
            print(
                "ROW|\(c.id)|enginePartial=\(e.partial ?? "—")|engineEnd=\(e.defaultEnd)|engineSeg=\(e.segmentize)|engineStrip=\(e.strip.map(String.init) ?? "—")|imeSegMode=\(i.segMode)|imeEnd=\(i.clauseEnd.map(String.init) ?? "—")|imeSelected=\(i.selected ?? "—")|imeSegTexts=\(i.segments)|imeRemain=\(i.remaining ?? "—")|imeCands=\(i.cands)"
            )
        }
        XCTAssertTrue(true)
    }

    func testKonnitihaFirstClausePartialLengths() {
        let reading = "こんにちは"
        let raw = engine.requestConversionResult(
            hiragana: reading,
            leftSideContext: nil,
            richCandidates: true
        )
        let partials = raw.firstClauseResults
            .filter { !AzooKeyCandidateMerge.consumesWholeTarget($0.inputLength, convertTarget: reading) }
            .map { "\($0.text):\($0.inputLength)" }
        print("KONNICHIHA|firstClausePartials=\(partials)")
        print("KONNICHIHA|mainHead=\(raw.mainResults.prefix(5).map { "\($0.text):\($0.inputLength)" })")
    }

    func testAnatahaEnterLeavesHa() {
        setUp()
        typeRomaji("anataha")
        press(keyCode: 49)
        press(keyCode: 36)
        XCTAssertEqual(handler.state.composedHiragana, "は")
        XCTAssertTrue(handler.state.isSegmentMode)
    }
}
