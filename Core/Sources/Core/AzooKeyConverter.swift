import Foundation
import os
import KanaKanjiConverterModuleWithDefaultDictionary

private let spLog = OSLog(subsystem: "jp.leaner.keynaco", category: "AzooKey")

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
    // MARK: - candidateCache（読み書き LRU）
    //
    // `requestCandidates` の結果 `[Candidate]` を `(hiragana, leftSideContext, richCandidates)` キーで保持。
    // 同一キー再要求時は KanaKanjiConverter（Zenzai 推論含む）をスキップする。
    // `commit(reading:text:)` は確定語学習のため `[Candidate]` 本体を参照する。
    //
    // かつて `InputHandler.lastAzooKey*` が whileTyping 専用に持っていた重複回避は本キャッシュに統合済み。

    // llama_context (Zenzai) は非スレッドセーフ。LockedConverter が全 converter.* 呼び出しを直列化する。
    private let locked = LockedConverter()
    private var candidateCache: [String: [Candidate]] = [:]
    private var candidateCacheKeys: [String] = []
    private let candidateCacheLimit = 200
    /// whileTyping 非 pause 時の Zenzai `inferenceLimit`（PLAN260704b A2）。pause / explicit は既定 5。
    public static let whileTypingInferenceLimit = 2
    private let baseOptions: ConvertRequestOptions
    private let memoryURL: URL
    private let zenzaiEnabled: Bool

    /// ユーザー設定の Zenzai 有効フラグ。モデル URL 未取得などで実リランキングがフォールバックしていても `true` になり得る（ベストエフォート。プロモート行は辞書 top-1）。
    public var isZenzaiEnabled: Bool { zenzaiEnabled }
    public let latencyStats = TypingLatencyStats()
    public let fetchLogger = FetchLogger()
    private let zenzaiProfile: String
    private let zenzaiInferenceLimit: Int
    private var commitLockURL: URL { memoryURL.appendingPathComponent(".commit_lock") }

    var candidateCacheCount: Int { candidateCache.count }

    private static func cacheKey(segment: String, leftSideContext: String?, richCandidates: Bool) -> String {
        // 読み2文字以下はZenzaiの文脈効果がほぼなく、文脈をキーに含めるとミス率が急増するため除外する
        let ctx = segment.count <= 2 ? "" : (leftSideContext ?? "")
        return richCandidates ? "\(segment)|\(ctx)|rich" : "\(segment)|\(ctx)"
    }

    private static func displayCandidates(from candidates: [Candidate], inputLength: Int) -> [AzooKeyCandidate] {
        let filtered = filterCandidatesForDisplay(candidates, inputLength: inputLength)
        let source = filtered.isEmpty ? candidates : filtered
        return source.map { candidate in
            let segments = candidate.data.map { element in
                AzooKeySegmentSnapshot(
                    word: element.word,
                    ruby: element.ruby,
                    lcid: element.lcid,
                    rcid: element.rcid,
                    isJoshiLcid: CIDData.isJoshi(cid: element.lcid),
                    isJoshiRcid: CIDData.isJoshi(cid: element.rcid)
                )
            }
            return AzooKeyCandidate(
                text: candidate.text,
                shouldTrimTrailingJoshi: shouldTrimTrailingJoshi(segments: segments)
            )
        }
    }

    /// XCTest 並列実行時に学習メモリのファイル競合を避けるため、テスト中はインスタンスごとに隔離する。
    private static func defaultMemoryURL() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("keynaco")
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("keynaco-tests-\(UUID().uuidString)", isDirectory: true)
        }
        return appSupport
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
            let evict = evictableCacheKey() ?? candidateCacheKeys.first
            if let evict {
                candidateCacheKeys.removeAll { $0 == evict }
                candidateCache.removeValue(forKey: evict)
            }
        }
        candidateCache[key] = value
        candidateCacheKeys.append(key)
    }

    /// 読み 2 文字以下のキャッシュキーは pinned 扱いで LRU から除外する（PLAN260704b A4）。
    private func evictableCacheKey() -> String? {
        candidateCacheKeys.first { Self.cacheSegment(fromCacheKey: $0).count > 2 }
    }

    public convenience init() {
        self.init(zenzaiEnabled: false, zenzaiProfile: "", zenzaiInferenceLimit: 5)
    }

    public init(zenzaiEnabled: Bool = false, zenzaiProfile: String = "", zenzaiInferenceLimit: Int = 5) {
        self.zenzaiEnabled = zenzaiEnabled
        self.zenzaiProfile = zenzaiProfile
        self.zenzaiInferenceLimit = max(1, min(zenzaiInferenceLimit, 50))
        self.memoryURL = Self.defaultMemoryURL()
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
            // E2E 検証・採用判断: POC260529b（2026-06-05 卒業）。
            requireJapanesePrediction: .autoMix,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            learningType: .inputAndOutput,
            memoryDirectoryURL: memoryURL,
            sharedContainerURL: memoryURL,
            textReplacer: .empty,
            specialCandidateProviders: nil,
            metadata: nil
        )
    }

    public func peekCachedCandidates(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool = false
    ) -> AzooKeyCachePeek? {
        guard !hiragana.isEmpty else { return nil }
        let exactKey = Self.cacheKey(
            segment: hiragana,
            leftSideContext: leftSideContext,
            richCandidates: richCandidates
        )
        if let cached = candidateCache[exactKey] {
            let items = Self.displayCandidates(from: cached, inputLength: hiragana.count)
            guard !items.isEmpty else { return nil }
            let peek = AzooKeyCachePeek(candidates: items, match: .exact)
            recordCachePeek(hiragana: hiragana, peek: peek)
            return peek
        }
        var bestPrefix: String?
        var bestCandidates: [Candidate]?
        for key in candidateCacheKeys.reversed() {
            let segment = Self.cacheSegment(fromCacheKey: key)
            guard segment.count < hiragana.count, hiragana.hasPrefix(segment) else { continue }
            guard key == Self.cacheKey(segment: segment, leftSideContext: leftSideContext, richCandidates: richCandidates) else { continue }
            if let current = bestPrefix, segment.count <= current.count { continue }
            bestPrefix = segment
            bestCandidates = candidateCache[key]
        }
        if let segment = bestPrefix, let cached = bestCandidates {
            let items = Self.displayCandidates(from: cached, inputLength: segment.count)
            guard !items.isEmpty else { return nil }
            let peek = AzooKeyCachePeek(candidates: items, match: .prefix(sourceReading: segment))
            recordCachePeek(hiragana: hiragana, peek: peek)
            return peek
        }
        recordCachePeek(hiragana: hiragana, peek: nil)
        return nil
    }

    private func recordCachePeek(hiragana: String, peek: AzooKeyCachePeek?) {
        let label: String
        let kind: TypingLatencyStats.CachePeekKind
        if let peek {
            switch peek.match {
            case .exact:
                label = "exact"
                kind = .exact
            case .prefix:
                label = "prefix"
                kind = .prefix
            }
        } else {
            label = "miss"
            kind = .miss
        }
        os_log(.debug, log: spLog, "cachePeek %{public}s → %{public}s", hiragana, label)
        latencyStats.recordCachePeek(kind, readingLength: hiragana.count)
    }

    public func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool = false) -> [AzooKeyCandidate] {
        requestCandidates(
            hiragana: hiragana,
            leftSideContext: leftSideContext,
            richCandidates: richCandidates,
            options: .default
        )
    }

    public func requestCandidates(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool,
        options: AzooKeyFetchOptions
    ) -> [AzooKeyCandidate] {
        let key = Self.cacheKey(segment: hiragana, leftSideContext: leftSideContext, richCandidates: richCandidates)
        let inputLength = hiragana.count
        if let cached = candidateCache[key] {
            insertCache(key: key, value: cached)
            return Self.displayCandidates(from: cached, inputLength: inputLength)
        }
        var text = ComposingText()
        text.insertAtCursorPosition(hiragana, inputStyle: .direct)
        let convertOptions = makeOptions(
            leftSideContext: leftSideContext,
            richCandidates: richCandidates,
            inferenceLimit: options.zenzaiInferenceLimit
        )
        let lockRequestedAt = CFAbsoluteTimeGetCurrent()
        let abortBeforeFetch = options.abortBeforeFetch
        return locked.withLock { c in
            if abortBeforeFetch?() == true {
                return [AzooKeyCandidate]()
            }
            let lockWaitMs = (CFAbsoluteTimeGetCurrent() - lockRequestedAt) * 1000
            os_signpost(.begin, log: spLog, name: "requestCandidates", "%{public}s", hiragana)
            let t0 = CFAbsoluteTimeGetCurrent()
            let result = c.requestCandidates(text, options: convertOptions)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            os_signpost(.end, log: spLog, name: "requestCandidates")
            os_log(.debug, log: spLog, "requestCandidates %.1fms (lockWait %.1fms) %{public}s zenzai=%d", elapsedMs, lockWaitMs, hiragana, zenzaiEnabled ? 1 : 0)
            latencyStats.recordFetch(ms: elapsedMs, lockWaitMs: lockWaitMs, zenzaiEnabled: zenzaiEnabled, readingLength: hiragana.count)
            fetchLogger.append(
                reading: hiragana,
                leftContext: leftSideContext,
                fetchMs: elapsedMs,
                lockWaitMs: lockWaitMs,
                rich: richCandidates,
                zenzaiEnabled: zenzaiEnabled
            )
            insertCache(key: key, value: result.mainResults)
            return Self.displayCandidates(from: result.mainResults, inputLength: inputLength)
        }
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

    private func makeOptions(
        leftSideContext: String?,
        richCandidates: Bool = false,
        inferenceLimit: Int? = nil
    ) -> ConvertRequestOptions {
        var opts = baseOptions
        guard zenzaiEnabled, let modelURL = zenzaiModelURL else { return opts }
        let limit = inferenceLimit ?? zenzaiInferenceLimit
        opts.zenzaiMode = .on(
            weight: modelURL,
            inferenceLimit: limit,
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

    private static func endsWithKanji(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        return (0x4E00...0x9FFF).contains(last.value)
            || (0x3400...0x4DBF).contains(last.value)
            || last.value == 0x3005
    }

    /// 残余・予測補完フィルタ（POC260529b'）。削除不可。
    /// AzooKey は読みより長い予測補完候補も返すため、外すと完全一致が大幅に後退する
    /// （例: "かくにん" → "角煮ん"が1位、"確認"が205位）。完全一致優先はこのフィルタが担っている。
    static func filterCandidatesForDisplay(_ candidates: [Candidate], inputLength: Int) -> [Candidate] {
        let fullCoverage = candidates.filter { composingCountValueStatic($0) == inputLength }
        let predictionFiltered = fullCoverage.filter { c in
            let rubySum = c.data.reduce(0) { $0 + $1.ruby.count }
            guard rubySum > inputLength else { return true }
            return endsWithKanji(c.text)
        }
        let validCoverage = predictionFiltered.filter { c in
            let segmentCount = c.data.count
            if segmentCount == 1 { return true }
            guard segmentCount >= 2, let lastSegment = c.data.last else { return true }
            if lastSegment.word.count > 1 { return true }
            if endsWithKanji(c.text) { return true }
            guard let scalar = lastSegment.word.unicodeScalars.first,
                  lastSegment.word.count == 1 else { return true }
            let isKana = KanaUtils.isHiragana(scalar) || KanaUtils.isKatakana(scalar)
            guard isKana else { return true }
            return isFunctionalKanaTail(lcid: lastSegment.lcid)
        }
        let base = validCoverage.isEmpty ? predictionFiltered : validCoverage
        var exact = [Candidate]()
        var rest = [Candidate]()
        for c in base {
            let rubySum = c.data.reduce(0) { $0 + $1.ruby.count }
            // `getAdditionalCandidate` が生成する機械生成候補（カタカナ / ひらがな / 大文字 ASCII 等）は
            // どれも `data.ruby == 入力読みの toKatakana()` で lcid=固有名詞(1288)。
            // ruby が全カタカナかつ固有名詞 lcid なら辞書ヒットではない＝ exact プロモートから外す。
            // 辞書の固有名詞（「内閣府」「マイクロソフト」等）は ruby がひらがな登録なので除外されない。
            let isMachineGenerated = c.data.count == 1
                && c.data.first.map { d in
                    d.lcid == CIDData.固有名詞.cid
                    && !d.ruby.isEmpty
                    && d.ruby.unicodeScalars.allSatisfy(KanaUtils.isKatakana)
                } ?? false
            if c.data.count == 1 && rubySum == inputLength && !isMachineGenerated {
                exact.append(c)
            } else {
                rest.append(c)
            }
        }
        return exact + rest
    }

    /// 末尾 1 文字かなセグメントが助詞・助動詞か（旧 validCoverage の lcid 147…554 をセグメント＋名前付き判定に置換）。
    private static func isFunctionalKanaTail(lcid: Int) -> Bool {
        CIDData.isJoshi(cid: lcid) || (369...554).contains(lcid)
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

    /// キャッシュから候補の canonical reading（各 data 要素の ruby を連結）を返す。
    /// prefix-focus で短い読みで確定した場合に、本来の読みで履歴を保存するために使う。
    /// キャッシュミス（未変換 or キャッシュ evict 済み）の場合は nil。
    public func canonicalReading(for reading: String, text: String) -> String? {
        locked.withLock { _ in
            for (key, candidates) in candidateCache where Self.cacheSegment(fromCacheKey: key) == reading {
                if let candidate = candidates.first(where: { $0.text == text }) {
                    let ruby = candidate.data.map(\.ruby).joined()
                    return ruby.isEmpty ? nil : ruby
                }
            }
            return nil
        }
    }

    /// キャッシュ上の候補の `data` セグメント構成（PLAN260710a POC ゲート用）。
    /// `requestCandidates` 済みでキャッシュに残っていることが前提。ミスなら nil。
    public func segmentSnapshots(for reading: String, text: String) -> [AzooKeySegmentSnapshot]? {
        locked.withLock { _ in
            for (key, candidates) in candidateCache where Self.cacheSegment(fromCacheKey: key) == reading {
                if let candidate = candidates.first(where: { $0.text == text }) {
                    return candidate.data.map { element in
                        AzooKeySegmentSnapshot(
                            word: element.word,
                            ruby: element.ruby,
                            lcid: element.lcid,
                            rcid: element.rcid,
                            isJoshiLcid: CIDData.isJoshi(cid: element.lcid),
                            isJoshiRcid: CIDData.isJoshi(cid: element.rcid)
                        )
                    }
                }
            }
            return nil
        }
    }

    /// PLAN260710a の trim 条件: セグメント 2 以上かつ末尾 lcid が joshi。
    public static func shouldTrimTrailingJoshi(segments: [AzooKeySegmentSnapshot]) -> Bool {
        guard segments.count >= 2, let last = segments.last else { return false }
        return last.isJoshiLcid
    }

    /// `cacheKey` の先頭セグメント（`|` より前）を読みとして取り出す。
    private static func cacheSegment(fromCacheKey key: String) -> String {
        guard let idx = key.firstIndex(of: "|") else { return key }
        return String(key[..<idx])
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
