import XCTest
@testable import KeynacoCore

@MainActor
final class POSCommitSequencerTests: XCTestCase {

    private final class MockClassifier: POSCommitSequencer.Classifying {
        struct PendingJob {
            let output: String
            let context: String?
            let completion: @MainActor (String, String, String, Bool, String?) -> Void
        }

        var pendingJobs: [PendingJob] = []

        func enqueue(
            output: String,
            context: String?,
            completion: @escaping @MainActor (String, String, String, Bool, String?) -> Void
        ) {
            pendingJobs.append(PendingJob(output: output, context: context, completion: completion))
        }

        func completeNext(
            pos: String,
            posTag: String = "noun:high",
            posRetry: Bool = false,
            lemma: String? = nil
        ) {
            guard !pendingJobs.isEmpty else {
                XCTFail("no pending classifier jobs")
                return
            }
            let job = pendingJobs.removeFirst()
            job.completion(job.output, pos, posTag, posRetry, lemma)
        }
    }

    private func seedCachedPOS(
        db: DatabaseManager,
        reading: String,
        output: String,
        pos: String,
        posTag: String = "noun:high",
        lemma: String? = nil
    ) {
        db.recordPrefixes(reading: reading, output: output)
        db.updatePOS(output: output, pos: pos, posTag: posTag, lemma: lemma, posRetry: false)
    }

    private func makeSequencer(
        db: DatabaseManager,
        classifier: MockClassifier
    ) -> POSCommitSequencer {
        POSCommitSequencer(db: db, classifier: classifier)
    }

    func testCachedCommitsRecordContentBigramInCommitOrder() {
        let db = DatabaseManager(inMemory: true)
        let classifier = MockClassifier()
        let sequencer = makeSequencer(db: db, classifier: classifier)
        seedCachedPOS(db: db, reading: "とうきょう", output: "東京", pos: "proper_noun/place", posTag: "proper_noun/place:high")
        seedCachedPOS(db: db, reading: "ni", output: "に", pos: "particle", posTag: "particle:high")
        seedCachedPOS(db: db, reading: "あめ", output: "雨", pos: "noun", posTag: "noun:high")

        var lastContentWord: String?
        let state = POSCommitSequencer.ContentWordState(get: { lastContentWord }, set: { lastContentWord = $0 })

        sequencer.commit(output: "東京", reading: "とうきょう", contentWordState: state)
        sequencer.commit(output: "に", reading: "に", contentWordState: state)
        sequencer.commit(output: "雨", reading: "あめ", contentWordState: state)
        db.recordContentBigram(prev: "東京", input: "あめ", output: "雨")

        XCTAssertEqual(lastContentWord, "雨")
        XCTAssertEqual(db.fetchContentBigram(prev: "東京", reading: "あめ"), ["雨"])
        XCTAssertTrue(db.fetchContentBigram(prev: "東京", reading: "に").isEmpty)
        XCTAssertTrue(classifier.pendingJobs.isEmpty)
    }

    func testLLMPendingCommitBlocksLaterCachedSideEffects() {
        let db = DatabaseManager(inMemory: true)
        let classifier = MockClassifier()
        let sequencer = makeSequencer(db: db, classifier: classifier)
        seedCachedPOS(db: db, reading: "ni", output: "に", pos: "particle", posTag: "particle:high")
        seedCachedPOS(db: db, reading: "あめ", output: "雨", pos: "noun", posTag: "noun:high")

        var lastContentWord: String?
        let state = POSCommitSequencer.ContentWordState(get: { lastContentWord }, set: { lastContentWord = $0 })

        sequencer.commit(output: "東京", reading: "とうきょう", contentWordState: state)
        sequencer.commit(output: "に", reading: "に", contentWordState: state)
        sequencer.commit(output: "雨", reading: "あめ", contentWordState: state)

        XCTAssertNil(lastContentWord)
        XCTAssertTrue(db.fetchAllContentBigram().isEmpty)
        XCTAssertEqual(classifier.pendingJobs.count, 1)
        XCTAssertEqual(classifier.pendingJobs[0].output, "東京")

        classifier.completeNext(pos: "proper_noun/place", posTag: "proper_noun/place:high")

        XCTAssertEqual(lastContentWord, "雨")
        db.recordContentBigram(prev: "東京", input: "あめ", output: "雨")
        XCTAssertEqual(db.fetchContentBigram(prev: "東京", reading: "あめ"), ["雨"])
        XCTAssertTrue(db.fetchContentBigram(prev: "東京", reading: "に").isEmpty)
        XCTAssertTrue(classifier.pendingJobs.isEmpty)
    }

    func testSameOutputSharesSingleLLMResult() {
        let db = DatabaseManager(inMemory: true)
        let classifier = MockClassifier()
        let sequencer = makeSequencer(db: db, classifier: classifier)

        var lastContentWord: String?
        let state = POSCommitSequencer.ContentWordState(get: { lastContentWord }, set: { lastContentWord = $0 })

        sequencer.commit(output: "東京", reading: "とうきょう", contentWordState: state)
        sequencer.commit(output: "東京", reading: "とうきょう", contentWordState: state)

        XCTAssertEqual(classifier.pendingJobs.count, 1)

        classifier.completeNext(pos: "proper_noun/place", posTag: "proper_noun/place:high")

        XCTAssertEqual(lastContentWord, "東京")
        let rows = db.fetchAllContentBigram()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].prev, "東京")
        XCTAssertEqual(rows[0].output, "東京")
    }

    func testVerbLemmaFromLLMStoredAsContentWordPrev() {
        let db = DatabaseManager(inMemory: true)
        let classifier = MockClassifier()
        let sequencer = makeSequencer(db: db, classifier: classifier)
        seedCachedPOS(db: db, reading: "とうきょう", output: "東京", pos: "proper_noun/place", posTag: "proper_noun/place:high")
        seedCachedPOS(db: db, reading: "がっこう", output: "学校", pos: "noun", posTag: "noun:high")

        var lastContentWord: String?
        let state = POSCommitSequencer.ContentWordState(get: { lastContentWord }, set: { lastContentWord = $0 })

        sequencer.commit(output: "東京", reading: "とうきょう", contentWordState: state)
        db.recordPrefixes(reading: "いった", output: "行った")
        sequencer.commit(output: "行った", reading: "いった", contentWordState: state)
        classifier.completeNext(pos: "verb", posTag: "verb:high", lemma: "行く")
        sequencer.commit(output: "学校", reading: "がっこう", contentWordState: state)
        db.recordContentBigram(prev: "行く", input: "がっこう", output: "学校")

        XCTAssertEqual(lastContentWord, "学校")
        XCTAssertEqual(db.fetchCachedPOS(output: "行った")?.lemma, "行く")
        XCTAssertEqual(db.fetchContentBigram(prev: "行く", reading: "がっこ"), ["学校"])
    }

    func testCachedVerbLemmaReusedOnSecondCommit() {
        let db = DatabaseManager(inMemory: true)
        let classifier = MockClassifier()
        let sequencer = makeSequencer(db: db, classifier: classifier)
        seedCachedPOS(
            db: db, reading: "いった", output: "行った",
            pos: "verb", posTag: "verb:high", lemma: "行く"
        )
        seedCachedPOS(db: db, reading: "がっこう", output: "学校", pos: "noun", posTag: "noun:high")

        var lastContentWord: String?
        let state = POSCommitSequencer.ContentWordState(get: { lastContentWord }, set: { lastContentWord = $0 })

        sequencer.commit(output: "行った", reading: "いった", contentWordState: state)
        sequencer.commit(output: "学校", reading: "がっこう", contentWordState: state)
        db.recordContentBigram(prev: "行く", input: "がっこう", output: "学校")

        XCTAssertEqual(lastContentWord, "学校")
        XCTAssertTrue(classifier.pendingJobs.isEmpty)
        XCTAssertEqual(db.fetchContentBigram(prev: "行く", reading: "がっこ"), ["学校"])
    }
}
