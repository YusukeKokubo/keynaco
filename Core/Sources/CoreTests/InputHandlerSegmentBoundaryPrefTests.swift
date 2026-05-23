import XCTest
@testable import KeynacoCore

// boundary_pref（B-1 手動境界）。docs/domain/glossary.md DatabaseManager 参照。

final class InputHandlerSegmentBoundaryPrefTests: InputHandlerTestCase {

    // MARK: - B-1 境界学習

    func testBoundaryPrefSavedOnManualAdjust() {
        typeRomaji("kyouha")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss = handler.state.segmentState,
              ss.segments.count >= 2 else { return }
        press(keyCode: 123, modifiers: .shift)
        press(keyCode: 36)
        XCTAssertNotNil(handler.db.fetchBoundaryPref(fullReading: "きょうは"),
                        "手動調整後に boundary_pref が保存されるはず")
    }

    func testBoundaryPrefReproducedOnReenter() {
        typeRomaji("kyouha")
        press(keyCode: 49)
        guard handler.state.isSegmentMode,
              let ss = handler.state.segmentState,
              ss.segments.count >= 2 else { return }
        press(keyCode: 123, modifiers: .shift)
        guard let adjusted = handler.state.segmentState else { return }
        let adjustedReadings = adjusted.segments.map { $0.reading }
        press(keyCode: 36)

        typeRomaji("kyouha")
        press(keyCode: 49)
        guard handler.state.isSegmentMode, let ss2 = handler.state.segmentState else { return }
        XCTAssertEqual(ss2.segments.map { $0.reading }, adjustedReadings,
                       "再入力時に保存済み境界が再現されるはず")
    }

    func testBoundaryPrefNotSavedWithoutAdjust() {
        typeRomaji("kyouha")
        press(keyCode: 49)
        guard handler.state.isSegmentMode else { return }
        press(keyCode: 36)
        XCTAssertNil(handler.db.fetchBoundaryPref(fullReading: "きょうは"),
                     "手動調整なしの確定では boundary_pref に保存されないはず")
    }

    func testBoundaryPrefFallbackToAzooKey() {
        XCTAssertNil(handler.db.fetchBoundaryPref(fullReading: "みらいのはなし"))
        typeRomaji("mirainohananashi")
        press(keyCode: 49)
        XCTAssertTrue(handler.state.isSegmentMode,
                      "DB にエントリがなくても AzooKey 分割でセグメントモードに入れるはず")
    }
}
