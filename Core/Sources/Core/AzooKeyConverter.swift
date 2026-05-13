import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

public final class AzooKeyConverter: @unchecked Sendable {
    private let converter = KanaKanjiConverter.withDefaultDictionary()
    private var candidateCache: [String: [Candidate]] = [:]
    private var candidateCacheKeys: [String] = []
    private let candidateCacheLimit = 50
    private let baseOptions: ConvertRequestOptions
    private let memoryURL: URL
    private let zenzaiEnabled: Bool

    /// ユーザー設定の Zenzai 有効フラグ。モデル URL 未取得などで実リランキングがフォールバックしていても `true` になり得る（ベストエフォート。プロモート行は辞書 top-1）。
    public var isZenzaiEnabled: Bool { zenzaiEnabled }
    private let zenzaiProfile: String
    private let zenzaiInferenceLimit: Int
    private var commitLockURL: URL { memoryURL.appendingPathComponent(".commit_lock") }

    public var candidateCacheCount: Int { candidateCache.count }

    private static func cacheKey(segment: String, leftSideContext: String?) -> String {
        "\(segment)|\(leftSideContext ?? "")"
    }

    private static func clearLearningData(at url: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: url.path) else { return }
        for file in files where file.hasPrefix("memory") {
            try? fm.removeItem(at: url.appendingPathComponent(file))
        }
    }

    /// アプリバンドル内の Zenzai 量子化モデル。見つからない場合は Zenzai をオフにフォールバックする。
    private var zenzaiModelURL: URL? {
        let u = Bundle.main.url(forResource: "ggml-model-Q5_K_M", withExtension: "gguf")
        guard let u, !u.path.isEmpty, FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

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

    public convenience init() {
        self.init(zenzaiEnabled: false, zenzaiProfile: "", zenzaiInferenceLimit: 5)
    }

    public init(zenzaiEnabled: Bool = false, zenzaiProfile: String = "", zenzaiInferenceLimit: Int = 5) {
        self.zenzaiEnabled = zenzaiEnabled
        self.zenzaiProfile = zenzaiProfile
        self.zenzaiInferenceLimit = max(1, min(zenzaiInferenceLimit, 50))
        let memoryURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("keynaco")
        self.memoryURL = memoryURL
        try? FileManager.default.createDirectory(at: memoryURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: memoryURL.appendingPathComponent(".commit_lock").path) {
            Self.clearLearningData(at: memoryURL)
            try? FileManager.default.removeItem(at: memoryURL.appendingPathComponent(".commit_lock"))
        }
        baseOptions = ConvertRequestOptions(
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

    private func makeOptions(leftSideContext: String?, richCandidates: Bool = false) -> ConvertRequestOptions {
        var opts = baseOptions
        guard zenzaiEnabled, let modelURL = zenzaiModelURL else { return opts }
        opts.zenzaiMode = .on(
            weight: modelURL,
            inferenceLimit: zenzaiInferenceLimit,
            requestRichCandidates: richCandidates,
            personalizationMode: nil,
            versionDependentMode: .v3(
                .init(
                    profile: zenzaiProfile.isEmpty ? nil : zenzaiProfile,
                    leftSideContext: leftSideContext
                )
            )
        )
        return opts
    }

    public func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool = false) -> [String] {
        let key = Self.cacheKey(segment: hiragana, leftSideContext: leftSideContext)
        var text = ComposingText()
        text.insertAtCursorPosition(hiragana, inputStyle: .direct)
        let result = converter.requestCandidates(text, options: makeOptions(leftSideContext: leftSideContext, richCandidates: richCandidates))
        insertCache(key: key, value: result.mainResults)
        let inputLength = hiragana.count
        let fullCoverage = result.mainResults.filter { composingCountValue($0) == inputLength }
        // data.count == 1 の単一辞書エントリ候補を優先する（複合変換の残余ひらがな付き候補を除外）
        let singleEntry = fullCoverage.filter { $0.data.count == 1 }
        let preferred = singleEntry.isEmpty ? fullCoverage : singleEntry
        return (preferred.isEmpty ? result.mainResults : preferred).map { $0.text }
    }

    public func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        let key = Self.cacheKey(segment: reading, leftSideContext: leftSideContext)
        var text = ComposingText()
        text.insertAtCursorPosition(reading, inputStyle: .direct)
        let result = converter.requestCandidates(text, options: makeOptions(leftSideContext: leftSideContext))
        insertCache(key: key, value: result.mainResults)
        return result.mainResults.map { $0.text }
    }

    public func commit(reading: String, text: String) {
        for (key, candidates) in candidateCache where Self.cacheSegment(fromCacheKey: key) == reading {
            if let candidate = candidates.first(where: { $0.text == text }) {
                FileManager.default.createFile(atPath: commitLockURL.path, contents: nil)
                converter.updateLearningData(candidate)
                converter.commitUpdateLearningData()
                try? FileManager.default.removeItem(at: commitLockURL)
                return
            }
        }
    }

    /// `cacheKey` の先頭セグメント（`|` より前）を読みとして取り出す。
    private static func cacheSegment(fromCacheKey key: String) -> String {
        guard let idx = key.firstIndex(of: "|") else { return key }
        return String(key[..<idx])
    }

    public func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])] {
        var segments: [(reading: String, candidates: [String])] = []
        var remaining = hiragana
        let opts = makeOptions(leftSideContext: leftSideContext)
        while !remaining.isEmpty {
            var text = ComposingText()
            text.insertAtCursorPosition(remaining, inputStyle: .direct)
            let result = converter.requestCandidates(text, options: opts)
            let clauseCandidates = result.firstClauseResults.isEmpty
                ? result.mainResults : result.firstClauseResults
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
            let ck = Self.cacheKey(segment: reading, leftSideContext: leftSideContext)
            let exactCoverage = clauseCandidates.filter { composingCountValue($0) == safeCount }
            let segmentCandidates = exactCoverage.isEmpty ? clauseCandidates : exactCoverage
            insertCache(key: ck, value: segmentCandidates)
            segments.append((reading: reading, candidates: segmentCandidates.map { $0.text }))
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
