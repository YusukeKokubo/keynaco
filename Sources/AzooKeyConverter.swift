import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

final class AzooKeyConverter: @unchecked Sendable {
    private let converter = KanaKanjiConverter.withDefaultDictionary()
    private var candidateCache: [String: [Candidate]] = [:]
    private let options: ConvertRequestOptions

    init() {
        let memoryURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("ykey")
        try? FileManager.default.createDirectory(at: memoryURL, withIntermediateDirectories: true)
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

    func requestCandidates(hiragana: String) -> [String] {
        var text = ComposingText()
        text.insertAtCursorPosition(hiragana, inputStyle: .direct)
        let result = converter.requestCandidates(text, options: options)
        candidateCache[hiragana] = result.mainResults
        return result.mainResults.map { $0.text }
    }

    func candidatesForSegment(reading: String) -> [String] {
        var text = ComposingText()
        text.insertAtCursorPosition(reading, inputStyle: .direct)
        let result = converter.requestCandidates(text, options: options)
        candidateCache[reading] = result.mainResults
        return result.mainResults.map { $0.text }
    }

    func commit(reading: String, text: String) {
        guard let candidates = candidateCache[reading],
              let candidate = candidates.first(where: { $0.text == text }) else { return }
        converter.updateLearningData(candidate)
        converter.commitUpdateLearningData()
    }

    func segmentize(_ hiragana: String) -> [(reading: String, candidates: [String])] {
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
            candidateCache[reading] = clauseCandidates
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
