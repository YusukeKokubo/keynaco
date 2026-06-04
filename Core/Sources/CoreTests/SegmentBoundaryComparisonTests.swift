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
        let end = AzooKeyCandidateMerge.defaultClauseEnd(
            result: raw,
            convertTarget: reading
        )
        return EngineRow(
            partial: partial.map { "\($0.text):\($0.inputLength)" },
            defaultEnd: end,
            segmentize: engine.segmentize(reading, leftSideContext: nil).map(\.reading).joined(separator: "|"),
            strip: AzooKeyCandidateMerge.clauseEndStrippingTrailingParticle(reading)
        )
    }

    private func setComposedReading(_ reading: String) {
        handler.state.composedHiragana = reading
    }

    private func imeAfterSpace(romaji: String? = nil, reading: String? = nil) -> (
        segMode: Bool,
        clauseEnd: Int?,
        selected: String?,
        segments: [String],
        cands: [String],
        remaining: String?
    ) {
        if let reading {
            setComposedReading(reading)
        } else if let romaji {
            typeRomaji(romaji)
        }
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
            let i = imeAfterSpace(romaji: c.romaji, reading: c.id == "4_konnitiha" ? c.reading : nil)
            let row =
                "ROW|\(c.id)|enginePartial=\(e.partial ?? "—")|engineEnd=\(e.defaultEnd)|engineSeg=\(e.segmentize)|engineStrip=\(e.strip.map(String.init) ?? "—")|imeSegMode=\(i.segMode)|imeEnd=\(i.clauseEnd.map(String.init) ?? "—")|imeSelected=\(i.selected ?? "—")|imeSegTexts=\(i.segments)|imeRemain=\(i.remaining ?? "—")|imeCands=\(i.cands)\n"
            fputs(row, stderr)
        }
        XCTAssertTrue(true)
    }

    func testKonnitihaFirstClausePartialLengths() {
        let reading = "こんにちは"
        let fresh = AzooKeyConverter()
        let raw = fresh.requestConversionResult(
            hiragana: reading,
            leftSideContext: nil,
            richCandidates: true
        )
        let partials = raw.firstClauseResults
            .filter { !AzooKeyCandidateMerge.consumesWholeTarget($0.inputLength, convertTarget: reading) }
            .map { "\($0.text):\($0.inputLength)" }
        let mainPartials = raw.mainResults
            .filter { !AzooKeyCandidateMerge.consumesWholeTarget($0.inputLength, convertTarget: reading) }
            .map { "\($0.text):\($0.inputLength)" }
        print("KONNICHIHA|firstClausePartials=\(partials)")
        print("KONNICHIHA|mainPartials=\(mainPartials)")
        print("KONNICHIHA|mainHead=\(raw.mainResults.prefix(8).map { "\($0.text):\($0.inputLength)" })")
    }

    func testAnatahaMainResultsPartialLengths() {
        let reading = "あなたは"
        let raw = AzooKeyConverter().requestConversionResult(
            hiragana: reading,
            leftSideContext: nil,
            richCandidates: true
        )
        let mainPartials = raw.mainResults
            .filter { !AzooKeyCandidateMerge.consumesWholeTarget($0.inputLength, convertTarget: reading) }
            .map { "\($0.text):\($0.inputLength)" }
        let firstPartials = raw.firstClauseResults
            .filter { !AzooKeyCandidateMerge.consumesWholeTarget($0.inputLength, convertTarget: reading) }
            .map { "\($0.text):\($0.inputLength)" }
        fputs("ANATAHA|mainPartials=\(mainPartials)\n", stderr)
        fputs("ANATAHA|firstPartials=\(firstPartials)\n", stderr)
    }

    /// Phase 1 POC: suffix 除去後は `こんにち|は` 分割（「今一」系）が起きないこと。
    func testKonnitihaSpaceDoesNotSplitHaOnlyRemainder() {
        setUp()
        setComposedReading("こんにちは")
        press(keyCode: 49)
        guard handler.state.isSegmentMode, let ss = handler.state.segmentState else {
            XCTFail("文節モードに入るはず")
            return
        }
        XCTAssertEqual(ss.effectiveClauseEnd, 4, "こんにち|は（最長部分 4）")
        XCTAssertEqual(ss.remainingReading, "は")
        let firstCand = ss.current.selectedText ?? ""
        XCTAssertFalse(firstCand.hasPrefix("今一"), "先頭が今一系にならない: \(firstCand)")
        XCTAssertFalse(firstCand.hasPrefix("艮"), "艮一系を選ばない: \(firstCand)")
        XCTAssertTrue(
            firstCand == "こんにち" || firstCand == "今日",
            "先頭表層はこんにち/今日: \(firstCand)"
        )
    }

    func testWatashihagakuseiSpaceSplitsBeforeHa() {
        setUp()
        typeRomaji("watashihagakusei")
        press(keyCode: 49)
        guard handler.state.isSegmentMode, let ss = handler.state.segmentState else {
            XCTFail("文節モードに入るはず")
            return
        }
        XCTAssertEqual(ss.effectiveClauseEnd, 3, "わたし|はがくせい")
        XCTAssertEqual(ss.current.reading, "わたし")
        XCTAssertEqual(ss.remainingReading, "はがくせい")
        XCTAssertEqual(ss.current.selectedText, "わたし")
    }

    func testKonnitihaSpaceSelectsKonnichiNotKonichi() {
        setUp()
        setComposedReading("こんにちは")
        press(keyCode: 49)
        guard handler.state.isSegmentMode, let ss = handler.state.segmentState else {
            XCTFail("文節モードに入るはず")
            return
        }
        let selected = ss.current.selectedText ?? ""
        XCTAssertTrue(
            selected == "こんにち" || selected == "今日",
            "先頭表層はこんにち/今日のいずれか: \(selected)"
        )
        XCTAssertFalse(selected.hasPrefix("今一"), "今一系を選ばない: \(selected)")
        XCTAssertFalse(selected.hasPrefix("艮"), "艮一系を選ばない: \(selected)")
    }

    func testAnatahaEnterLeavesHa() {
        setUp()
        typeRomaji("anataha")
        press(keyCode: 49)
        press(keyCode: 36)
        XCTAssertEqual(handler.state.composedHiragana, "は")
        XCTAssertTrue(handler.state.isSegmentMode)
    }

    /// PLAN260603 チェックリスト #1–#4（実エンジン・境界長）
    func testPlan260603ChecklistSegmentBoundaries() {
        let cases: [(romaji: String, reading: String?, end: Int, remain: String)] = [
            ("anataha", nil, 3, "は"),
            ("gakuseidesu", nil, 4, "です"),
            ("watashihagakusei", nil, 3, "はがくせい"),
            ("konnitiha", "こんにちは", 4, "は"),
        ]
        for c in cases {
            setUp()
            if let fixedReading = c.reading {
                setComposedReading(fixedReading)
            } else {
                typeRomaji(c.romaji)
            }
            press(keyCode: 49)
            guard let ss = handler.state.segmentState else {
                XCTFail("\(c.romaji): 文節モードに入るはず"); continue
            }
            XCTAssertEqual(
                ss.effectiveClauseEnd, c.end,
                "\(c.romaji): 境界 \(c.end)"
            )
            XCTAssertEqual(ss.remainingReading, c.remain, "\(c.romaji): 残り")
        }
    }
}
