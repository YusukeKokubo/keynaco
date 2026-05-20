import XCTest
@testable import KeynacoCore

// See: plans/PLAN260520b.md

final class InputHandlerSuccessorPrefixTests: XCTestCase {

    // MARK: - splitSurfaceAtParticles

    func testSplitSurfaceAtParticles_meetingPhrase() {
        XCTAssertEqual(
            InputHandler.splitSurfaceAtParticles("会議に出席する"),
            ["会議", "会議に"]
        )
    }

    func testSplitSurfaceAtParticles_noParticle() {
        XCTAssertEqual(InputHandler.splitSurfaceAtParticles("予定です"), [])
    }

    func testSplitSurfaceAtParticles_multipleParticles() {
        XCTAssertEqual(
            InputHandler.splitSurfaceAtParticles("東京から大阪へ"),
            ["東京", "東京から", "東京から大阪"]
        )
    }

    func testSplitSurfaceAtParticles_leadingParticleIgnored() {
        XCTAssertEqual(InputHandler.splitSurfaceAtParticles("にこにこ"), [])
    }

    func testSplitSurfaceAtParticles_trailingParticleEqualsParent() {
        XCTAssertEqual(InputHandler.splitSurfaceAtParticles("私は"), ["私"])
    }

    func testSplitSurfaceAtParticles_singleCharacter() {
        XCTAssertEqual(InputHandler.splitSurfaceAtParticles("お"), [])
    }

    // MARK: - expandSuccessorPrefixes

    func testExpandSuccessorPrefixes_twoParentsNounEndFirst() {
        XCTAssertEqual(
            InputHandler.expandSuccessorPrefixes(candidates: ["会議に出席する", "予定です"]),
            ["会議", "会議に", "会議に出席する", "予定です"]
        )
    }

    func testExpandSuccessorPrefixes_maxPerParentOne() {
        XCTAssertEqual(
            InputHandler.expandSuccessorPrefixes(
                candidates: ["会議に出席する", "予定です"],
                maxPerParent: 1
            ),
            ["会議", "会議に出席する", "予定です"]
        )
    }

    func testExpandSuccessorPrefixes_deduplicatesAcrossParents() {
        let result = InputHandler.expandSuccessorPrefixes(
            candidates: ["会議に出席する", "会議に出席する"]
        )
        XCTAssertEqual(result, ["会議", "会議に", "会議に出席する"])
    }

    func testExpandSuccessorPrefixes_totalLimit() {
        let parents = (0..<10).map { "語\($0)に続く" }
        let result = InputHandler.expandSuccessorPrefixes(candidates: parents)
        XCTAssertEqual(result.count, LearningThresholds.successorMaxCandidates)
    }
}
