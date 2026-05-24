import Foundation

/// POS 分類（DB キャッシュ / LLM）と noun_bigram 記録を分離し、確定順で副作用を適用する。
@MainActor
public final class POSCommitSequencer {
    public struct Classification: Sendable, Equatable {
        public let pos: String
        public let posTag: String
        public let posRetry: Bool

        public init(pos: String, posTag: String, posRetry: Bool) {
            self.pos = pos
            self.posTag = posTag
            self.posRetry = posRetry
        }
    }

    /// LLM 分類の抽象。`LLMPOSClassifier` が準拠する。
    @MainActor
    public protocol Classifying: AnyObject {
        func enqueue(
            output: String,
            context: String?,
            completion: @escaping @MainActor (_ output: String, _ pos: String, _ posTag: String, _ posRetry: Bool) -> Void
        )
    }

    public struct NounState {
        public var get: @MainActor () -> String?
        public var set: @MainActor (String) -> Void

        public init(
            get: @escaping @MainActor () -> String?,
            set: @escaping @MainActor (String) -> Void
        ) {
            self.get = get
            self.set = set
        }
    }

    private struct PendingCommit {
        let id: UInt64
        let output: String
        let reading: String
        let context: String?
        var classification: Classification?
    }

    private let db: DatabaseManager
    private let classifier: any Classifying
    private var pending: [PendingCommit] = []
    private var nextID: UInt64 = 0
    /// 同一 output の LLM が走行中なら追加 commit は結果を共有する。
    private var inFlightOutputs: Set<String> = []
    private var outputWaiterIDs: [String: [UInt64]] = [:]

    public init(db: DatabaseManager, classifier: any Classifying) {
        self.db = db
        self.classifier = classifier
    }

    /// 確定語を受け取り、POS 解決後に確定順で noun_bigram / lastConfirmedNounOutput を更新する。
    public func commit(
        output: String,
        reading: String,
        context: String? = nil,
        nounState: NounState
    ) {
        nextID += 1
        let entry = PendingCommit(
            id: nextID,
            output: output,
            reading: reading,
            context: context,
            classification: nil
        )
        pending.append(entry)
        beginResolution(for: entry.id, nounState: nounState)
    }

    private func beginResolution(for commitID: UInt64, nounState: NounState) {
        guard let index = pending.firstIndex(where: { $0.id == commitID }) else { return }
        let commit = pending[index]
        guard commit.classification == nil else { return }

        if let cached = db.fetchCachedPOS(output: commit.output) {
            resolve(commitID: commitID, classification: cached, nounState: nounState)
            return
        }

        let output = commit.output
        if inFlightOutputs.contains(output) {
            outputWaiterIDs[output, default: []].append(commitID)
            return
        }

        inFlightOutputs.insert(output)
        classifier.enqueue(output: output, context: commit.context) { [weak self] classifiedOutput, pos, posTag, posRetry in
            guard let self else { return }
            let classification = Classification(pos: pos, posTag: posTag, posRetry: posRetry)
            self.db.updatePOS(
                output: classifiedOutput,
                pos: pos,
                posTag: posTag,
                posRetry: posRetry
            )
            self.finishInFlightClassification(
                output: classifiedOutput,
                initiatorID: commitID,
                classification: classification,
                nounState: nounState
            )
        }
    }

    private func finishInFlightClassification(
        output: String,
        initiatorID: UInt64,
        classification: Classification,
        nounState: NounState
    ) {
        resolve(commitID: initiatorID, classification: classification, nounState: nounState)
        let waiterIDs = outputWaiterIDs.removeValue(forKey: output) ?? []
        for waiterID in waiterIDs {
            resolve(commitID: waiterID, classification: classification, nounState: nounState)
        }
        inFlightOutputs.remove(output)
    }

    private func resolve(
        commitID: UInt64,
        classification: Classification,
        nounState: NounState
    ) {
        guard let index = pending.firstIndex(where: { $0.id == commitID }) else { return }
        guard pending[index].classification == nil else { return }
        pending[index].classification = classification
        drainSideEffects(nounState: nounState)
    }

    private func drainSideEffects(nounState: NounState) {
        while let head = pending.first, let classification = head.classification {
            pending.removeFirst()
            applySideEffects(
                output: head.output,
                reading: head.reading,
                classification: classification,
                nounState: nounState
            )
        }
    }

    private func applySideEffects(
        output: String,
        reading: String,
        classification: Classification,
        nounState: NounState
    ) {
        guard classification.pos == "noun" || classification.pos.hasPrefix("proper_noun") else { return }
        if let prev = nounState.get() {
            db.recordNounBigram(prev: prev, input: reading, output: output)
        }
        nounState.set(output)
    }
}

extension LLMPOSClassifier: POSCommitSequencer.Classifying {}
