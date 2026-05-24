import XCTest
@testable import KeynacoCore

@MainActor
final class POSCommitSequencerTests: XCTestCase {

    private final class MockClassifier: POSCommitSequencer.Classifying {
        struct PendingJob {
            let output: String
            let context: String?
            let completion: @MainActor (String, String, String, Bool) -> Void
        }

        var pendingJobs: [PendingJob] = []

        func enqueue(
            output: String,
            context: String?,
            completion: @escaping @MainActor (String, String, String, Bool) -> Void
        ) {
            pendingJobs.append(PendingJob(output: output, context: context, completion: completion))
        }

        func completeNext(
            pos: String,
            posTag: String = "noun:high",
            posRetry: Bool = false
        ) {
            guard !pendingJobs.isEmpty else {
                XCTFail("no pending classifier jobs")
                return
            }
            let job = pendingJobs.removeFirst()
            job.completion(job.output, pos, posTag, posRetry)
        }
    }

    private func seedCachedPOS(
        db: DatabaseManager,
        reading: String,
        output: String,
        pos: String,
        posTag: String = "noun:high"
    ) {
        db.recordPrefixes(reading: reading, output: output)
        db.updatePOS(output: output, pos: pos, posTag: posTag, posRetry: false)
    }

    private func makeSequencer(
        db: DatabaseManager,
        classifier: MockClassifier
    ) -> POSCommitSequencer {
        POSCommitSequencer(db: db, classifier: classifier)
    }

    func testCachedCommitsRecordNounBigramInCommitOrder() {
        let db = DatabaseManager(inMemory: true)
        let classifier = MockClassifier()
        let sequencer = makeSequencer(db: db, classifier: classifier)
        seedCachedPOS(db: db, reading: "とうきょう", output: "東京", pos: "proper_noun/place", posTag: "proper_noun/place:high")
        seedCachedPOS(db: db, reading: "ni", output: "に", pos: "particle", posTag: "particle:high")
        seedCachedPOS(db: db, reading: "あめ", output: "雨", pos: "noun", posTag: "noun:high")

        var lastNoun: String?
        let nounState = POSCommitSequencer.NounState(get: { lastNoun }, set: { lastNoun = $0 })

        sequencer.commit(output: "東京", reading: "とうきょう", nounState: nounState)
        sequencer.commit(output: "に", reading: "に", nounState: nounState)
        sequencer.commit(output: "雨", reading: "あめ", nounState: nounState)

        XCTAssertEqual(lastNoun, "雨")
        XCTAssertEqual(db.fetchNounBigram(prev: "東京", reading: "あめ"), ["雨"])
        XCTAssertTrue(db.fetchNounBigram(prev: "東京", reading: "に").isEmpty)
        XCTAssertTrue(classifier.pendingJobs.isEmpty)
    }

    func testLLMPendingCommitBlocksLaterCachedSideEffects() {
        let db = DatabaseManager(inMemory: true)
        let classifier = MockClassifier()
        let sequencer = makeSequencer(db: db, classifier: classifier)
        seedCachedPOS(db: db, reading: "ni", output: "に", pos: "particle", posTag: "particle:high")
        seedCachedPOS(db: db, reading: "あめ", output: "雨", pos: "noun", posTag: "noun:high")

        var lastNoun: String?
        let nounState = POSCommitSequencer.NounState(get: { lastNoun }, set: { lastNoun = $0 })

        sequencer.commit(output: "東京", reading: "とうきょう", nounState: nounState)
        sequencer.commit(output: "に", reading: "に", nounState: nounState)
        sequencer.commit(output: "雨", reading: "あめ", nounState: nounState)

        XCTAssertNil(lastNoun)
        XCTAssertTrue(db.fetchAllNounBigram().isEmpty)
        XCTAssertEqual(classifier.pendingJobs.count, 1)
        XCTAssertEqual(classifier.pendingJobs[0].output, "東京")

        classifier.completeNext(pos: "proper_noun/place", posTag: "proper_noun/place:high")

        XCTAssertEqual(lastNoun, "雨")
        XCTAssertEqual(db.fetchNounBigram(prev: "東京", reading: "あめ"), ["雨"])
        XCTAssertTrue(db.fetchNounBigram(prev: "東京", reading: "に").isEmpty)
        XCTAssertTrue(classifier.pendingJobs.isEmpty)
    }

    func testSameOutputSharesSingleLLMResult() {
        let db = DatabaseManager(inMemory: true)
        let classifier = MockClassifier()
        let sequencer = makeSequencer(db: db, classifier: classifier)

        var lastNoun: String?
        let nounState = POSCommitSequencer.NounState(get: { lastNoun }, set: { lastNoun = $0 })

        sequencer.commit(output: "東京", reading: "とうきょう", nounState: nounState)
        sequencer.commit(output: "東京", reading: "とうきょう", nounState: nounState)

        XCTAssertEqual(classifier.pendingJobs.count, 1)

        classifier.completeNext(pos: "proper_noun/place", posTag: "proper_noun/place:high")

        XCTAssertEqual(lastNoun, "東京")
        let rows = db.fetchAllNounBigram()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].prev, "東京")
        XCTAssertEqual(rows[0].output, "東京")
    }
}
