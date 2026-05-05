import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

public final class AzooKeyConverter: @unchecked Sendable {
    private let converter = KanaKanjiConverter.withDefaultDictionary()
    private var candidateCache: [String: [Candidate]] = [:]
    private var candidateCacheKeys: [String] = []
    private let candidateCacheLimit = 50
    private let options: ConvertRequestOptions
    private let memoryURL: URL
    private var commitLockURL: URL { memoryURL.appendingPathComponent(".commit_lock") }

    public var candidateCacheCount: Int { candidateCache.count }

    private func insertCache(key: String, value: [Candidate]) {
        if candidateCache[key] != nil {
            candidateCacheKeys.removeAll { $0 == key }
        } else if candidateCache.count >= candidateCacheLimit {
            let evict = candidateCacheKeys.removeFirst()
            candidateCache.removeValue(forKey: evict)
        }
        candidateCache[key] = value
        candidateCacheKeys.append(key)
    }

    private static func clearLearningData(at url: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: url.path) else { return }
        for file in files where file.hasPrefix("memory") {
            try? fm.removeItem(at: url.appendingPathComponent(file))
        }
    }

    public init() {
        let memoryURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("keynaco")
        self.memoryURL = memoryURL
        try? FileManager.default.createDirectory(at: memoryURL, withIntermediateDirectories: true)
        // A commit_lock left over from a previous run means the process crashed mid-save.
        // AzooKey's LOUDS binary and metadata are then out of sync, which triggers an
        // assertion in LongTermLearningMemory.merge. Clear the memory files to recover.
        let lockURL = memoryURL.appendingPathComponent(".commit_lock")
        if FileManager.default.fileExists(atPath: lockURL.path) {
            Self.clearLearningData(at: memoryURL)
            try? FileManager.default.removeItem(at: lockURL)
        }
        options = ConvertRequestOptions(
            N_best: 10,
            requireJapanesePrediction: false,
            requireEnglishPrediction: false,
            keyboardLanguage: .ja_JP,
            learningType: .inputAndOutput,
            memoryDirectoryURL: memoryURL,
            sharedContainerURL: memoryURL,
            textReplacer: .empty,
            specialCandidateProviders: nil,
            metadata: nil
        )
    }

    public func requestCandidates(hiragana: String) -> [String] {
        var text = ComposingText()
        text.insertAtCursorPosition(hiragana, inputStyle: .direct)
        let result = converter.requestCandidates(text, options: options)
        insertCache(key: hiragana, value: result.mainResults)
        return result.mainResults.map { $0.text }
    }

    public func candidatesForSegment(reading: String) -> [String] {
        var text = ComposingText()
        text.insertAtCursorPosition(reading, inputStyle: .direct)
        let result = converter.requestCandidates(text, options: options)
        insertCache(key: reading, value: result.mainResults)
        return result.mainResults.map { $0.text }
    }

    public func commit(reading: String, text: String) {
        guard let candidates = candidateCache[reading],
              let candidate = candidates.first(where: { $0.text == text }) else { return }
        FileManager.default.createFile(atPath: commitLockURL.path, contents: nil)
        converter.updateLearningData(candidate)
        converter.commitUpdateLearningData()
        try? FileManager.default.removeItem(at: commitLockURL)
    }

    public func segmentize(_ hiragana: String) -> [(reading: String, candidates: [String])] {
        var segments: [(reading: String, candidates: [String])] = []
        var remaining = hiragana
        while !remaining.isEmpty {
            var text = ComposingText()
            text.insertAtCursorPosition(remaining, inputStyle: .direct)
            let result = converter.requestCandidates(text, options: options)
            let clauseCandidates = result.firstClauseResults.isEmpty
                ? result.mainResults : result.firstClauseResults
            // firstClauseResults are sorted by rubyCount desc, so [0] may cover the whole input.
            // Prefer the highest-value candidate that covers less than the entire remaining string.
            let totalLen = remaining.count
            let partialBest = clauseCandidates
                .filter { composingCountValue($0) < totalLen }
                .max(by: { $0.value < $1.value })
            let count: Int
            if let best = partialBest {
                count = composingCountValue(best)
            } else {
                count = clauseCandidates.first.map { composingCountValue($0) } ?? 1
            }
            let safeCount = max(1, min(count, totalLen))
            let reading = String(remaining.prefix(safeCount))
            insertCache(key: reading, value: clauseCandidates)
            segments.append((reading: reading, candidates: clauseCandidates.map { $0.text }))
            remaining = String(remaining.dropFirst(safeCount))
        }
        return segments
    }

    private func composingCountValue(_ candidate: Candidate) -> Int {
        countValue(candidate.composingCount)
    }

    private func countValue(_ count: ComposingCount) -> Int {
        switch count {
        case .inputCount(let n): return n
        case .surfaceCount(let n): return n
        case .composite(let lhs, let rhs): return countValue(lhs) + countValue(rhs)
        @unknown default: return 1
        }
    }
}
