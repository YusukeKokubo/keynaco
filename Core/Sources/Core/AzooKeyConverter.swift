import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// `KanaKanjiConverter`（内部に Zenzai の `llama_context` を持つ）を NSLock で包み、
/// **ロック保持中だけクロージャに貸し出す**ラッパー。
///
/// `llama_context` は非スレッドセーフ（推論ごとに内部状態を mutate する）ため、全アクセスを
/// 直列化しなければならない。このラッパーは `converter` をフィールドとして公開せず `withLock`
/// 経由でしか触れないようにすることで、「ロック貼り忘れ」を**コンパイルエラー**に変える
/// （素の `converter.xxx()` を書く手段が存在しない）。
///
/// 不変条件: `converter` の参照を `withLock` のクロージャ外へ持ち出さないこと（唯一残る抜け穴。
/// ただし貼り忘れと違い一目で分かるレビュー可能なミスに局所化される）。
private struct LockedConverter {
    private let converter = KanaKanjiConverter.withDefaultDictionary()
    private let lock = NSLock()

    func withLock<T>(_ body: (KanaKanjiConverter) -> T) -> T {
        lock.withLock { body(converter) }
    }
}

public final class AzooKeyConverter: @unchecked Sendable {
    // llama_context (Zenzai) は非スレッドセーフ。LockedConverter が全 converter.* 呼び出しを直列化する。
    private let locked = LockedConverter()
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

    // LockedConverter.withLock のクロージャ内（ロック保持中）から呼ぶこと
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
            // 組成中の予測補完。漢字を伸ばす内容語補完（内閣→内閣府/総理大臣）だけを候補に追加する。
            // AzooKey の予測は機能語尾ひれ（気がする+ん/の/し、わからない+の）や かな語完成
            // （考える/おはよう/ありがとう）も大量に吐くが、物理キーボードでは価値が薄くノイズ源になるため
            // requestCandidates 側で「ruby 長 > 入力長（=予測）かつ末尾表層が非漢字」を落とす（POC260529b'）。
            // 残った予測候補は composingCount==inputLength でカバレッジフィルタを通り dictionary セクションへ。
            // E2E 検証・経過観察: POC260529b / docs/observation.md。
            requireJapanesePrediction: true,
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
        let result = requestConversionResult(
            hiragana: hiragana,
            leftSideContext: leftSideContext,
            richCandidates: richCandidates
        )
        return result.mainResults.map(\.text)
    }

    /// azooKey-Desktop `SegmentsManager.updateRawCandidate` 相当の生結果。
    public func requestConversionResult(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool = false
    ) -> AzooKeyConversionResult {
        let key = Self.cacheKey(segment: hiragana, leftSideContext: leftSideContext)
        var text = ComposingText()
        text.insertAtCursorPosition(hiragana, inputStyle: .direct)
        let raw = locked.withLock { c -> (main: [Candidate], first: [Candidate]) in
            let r = c.requestCandidates(
                text,
                options: makeOptions(leftSideContext: leftSideContext, richCandidates: richCandidates)
            )
            insertCache(key: key, value: r.mainResults)
            return (r.mainResults, r.firstClauseResults)
        }
        let inputLength = hiragana.count
        return AzooKeyConversionResult(
            mainResults: Self.clauseCandidatesForMain(raw.main, inputLength: inputLength),
            firstClauseResults: Self.clauseCandidatesForFirstClause(raw.first, totalInputLength: inputLength)
        )
    }

    /// 全文候補リスト（`requestCandidates`）用。入力長ぴったりの候補のみ。
    private static func clauseCandidatesForMain(_ candidates: [Candidate], inputLength: Int) -> [AzooKeyClauseCandidate] {
        let filtered = filterCandidatesForDisplay(candidates, inputLength: inputLength)
        let source = filtered.isEmpty ? candidates : filtered
        return source.map {
            AzooKeyClauseCandidate(text: $0.text, inputLength: composingCountValueStatic($0))
        }
    }

    /// 先頭文節候補（`firstClauseResults`）。部分カバー候補を残す（Desktop `.selecting` 用）。
    private static func clauseCandidatesForFirstClause(
        _ candidates: [Candidate],
        totalInputLength: Int
    ) -> [AzooKeyClauseCandidate] {
        candidates.compactMap { c in
            let consumed = composingCountValueStatic(c)
            guard consumed > 0, consumed <= totalInputLength else { return nil }
            guard !isDanglingTrailingKanaResidual(c, consumed: consumed, totalInputLength: totalInputLength) else {
                return nil
            }
            return AzooKeyClauseCandidate(text: c.text, inputLength: consumed)
        }
    }

    /// 末尾 1 文字かな残余（「蛇あ」等）。`filterCandidatesForDisplay` と同じ判定。
    private static func isDanglingTrailingKanaResidual(
        _ c: Candidate,
        consumed: Int,
        totalInputLength: Int
    ) -> Bool {
        guard consumed < totalInputLength, c.data.count > 1, let last = c.data.last else { return false }
        guard last.word.count == 1, let scalar = last.word.unicodeScalars.first else { return false }
        let isHiragana = (0x3041...0x3096).contains(scalar.value)
        let isKatakana = (0x30A1...0x30F6).contains(scalar.value)
        guard isHiragana || isKatakana else { return false }
        return !(147...554).contains(last.lcid)
    }

    private static func composingCountValueStatic(_ candidate: Candidate) -> Int {
        inputLength(from: candidate.composingCount)
    }

    private static func inputLength(from count: ComposingCount) -> Int {
        switch count {
        case .inputCount(let n): return n
        case .surfaceCount(let n): return n
        case .composite(let lhs, let rhs): return inputLength(from: lhs) + inputLength(from: rhs)
        @unknown default: return 1
        }
    }

    /// `requestCandidates` と同じ残余・予測フィルタ（POC260529b'）。
    static func filterCandidatesForDisplay(_ candidates: [Candidate], inputLength: Int) -> [Candidate] {
        let fullCoverage = candidates.filter { composingCountValueStatic($0) == inputLength }
        let predictionFiltered = fullCoverage.filter { c in
            let rubySum = c.data.reduce(0) { $0 + $1.ruby.count }
            guard rubySum > inputLength else { return true }
            guard let last = c.text.unicodeScalars.last else { return true }
            let isKanji = (0x4E00...0x9FFF).contains(last.value)
                || (0x3400...0x4DBF).contains(last.value)
                || last.value == 0x3005
            return isKanji
        }
        let validCoverage = predictionFiltered.filter { c in
            guard c.data.count > 1, let last = c.data.last else { return true }
            guard last.word.count == 1, let scalar = last.word.unicodeScalars.first else { return true }
            let isHiragana = (0x3041...0x3096).contains(scalar.value)
            let isKatakana = (0x30A1...0x30F6).contains(scalar.value)
            guard isHiragana || isKatakana else { return true }
            return (147...554).contains(last.lcid)
        }
        return validCoverage.isEmpty ? predictionFiltered : validCoverage
    }

    public func candidatesForSegment(reading: String, leftSideContext: String?) -> [String] {
        let key = Self.cacheKey(segment: reading, leftSideContext: leftSideContext)
        var text = ComposingText()
        text.insertAtCursorPosition(reading, inputStyle: .direct)
        return locked.withLock { c in
            let result = c.requestCandidates(text, options: makeOptions(leftSideContext: leftSideContext))
            insertCache(key: key, value: result.mainResults)
            return result.mainResults.map { $0.text }
        }
    }

    public func commit(reading: String, text: String) {
        locked.withLock { c in
            for (key, candidates) in candidateCache where Self.cacheSegment(fromCacheKey: key) == reading {
                if let candidate = candidates.first(where: { $0.text == text }) {
                    FileManager.default.createFile(atPath: commitLockURL.path, contents: nil)
                    c.updateLearningData(candidate)
                    c.commitUpdateLearningData()
                    try? FileManager.default.removeItem(at: commitLockURL)
                    return
                }
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
            let (reading, segmentCandidates, consumed) = locked.withLock { c -> (String, [Candidate], Int) in
                let result = c.requestCandidates(text, options: opts)
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
                let seg = String(remaining.prefix(safeCount))
                let ck = Self.cacheKey(segment: seg, leftSideContext: leftSideContext)
                let exactCoverage = clauseCandidates.filter { composingCountValue($0) == safeCount }
                let segCandidates = exactCoverage.isEmpty ? clauseCandidates : exactCoverage
                insertCache(key: ck, value: segCandidates)
                return (seg, segCandidates, safeCount)
            }
            segments.append((reading: reading, candidates: segmentCandidates.map { $0.text }))
            remaining = String(remaining.dropFirst(consumed))
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

    /// 確定済み `(reading, output)` に対応する候補の代表 `lcid` を辞書ルックアップで返す（Zenzai 不使用）。
    public func lcidForCommitted(reading: String, output: String) -> Int? {
        guard !reading.isEmpty else { return nil }
        var text = ComposingText()
        text.insertAtCursorPosition(reading, inputStyle: .direct)
        return locked.withLock { c in
            let result = c.requestCandidates(text, options: baseOptions)
            guard let match = result.mainResults.first(where: { $0.text == output }) else { return nil }
            return Self.primaryLcid(from: match.data)
        }
    }

    private static func primaryLcid(from data: [DicdataElement]) -> Int? {
        if let content = data.first(where: { !CIDData.isJoshi(cid: $0.lcid) && $0.lcid != 0 && $0.lcid != CIDData.EOS.cid }) {
            return content.lcid
        }
        return data.first?.lcid
    }
}
