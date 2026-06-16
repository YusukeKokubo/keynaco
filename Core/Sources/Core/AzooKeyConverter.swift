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
    private let candidateCacheLimit = 50
    private let baseOptions: ConvertRequestOptions
    private let memoryURL: URL
    private let zenzaiEnabled: Bool

    /// ユーザー設定の Zenzai 有効フラグ。モデル URL 未取得などで実リランキングがフォールバックしていても `true` になり得る（ベストエフォート。プロモート行は辞書 top-1）。
    public var isZenzaiEnabled: Bool { zenzaiEnabled }
    private let zenzaiProfile: String
    private let zenzaiInferenceLimit: Int
    private var commitLockURL: URL { memoryURL.appendingPathComponent(".commit_lock") }

    var candidateCacheCount: Int { candidateCache.count }

    private static func cacheKey(segment: String, leftSideContext: String?, richCandidates: Bool) -> String {
        let ctx = leftSideContext ?? ""
        return richCandidates ? "\(segment)|\(ctx)|rich" : "\(segment)|\(ctx)"
    }

    private static func candidateTexts(from candidates: [Candidate], inputLength: Int) -> [String] {
        let filtered = filterCandidatesForDisplay(candidates, inputLength: inputLength)
        let source = filtered.isEmpty ? candidates : filtered
        return source.map(\.text)
    }

    private static func primaryLcidMap(from candidates: [Candidate], inputLength: Int) -> [String: Int] {
        let filtered = filterCandidatesForDisplay(candidates, inputLength: inputLength)
        let source = filtered.isEmpty ? candidates : filtered
        var map: [String: Int] = [:]
        map.reserveCapacity(source.count)
        for candidate in source {
            if let lcid = primaryLcid(from: candidate.data) {
                map[candidate.text] = lcid
            }
        }
        return map
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
            let texts = Self.candidateTexts(from: cached, inputLength: hiragana.count)
            guard !texts.isEmpty else { return nil }
            return AzooKeyCachePeek(candidates: texts, match: .exact)
        }
        let ctx = leftSideContext ?? ""
        let keySuffix = richCandidates ? "|\(ctx)|rich" : "|\(ctx)"
        var bestPrefix: String?
        var bestCandidates: [Candidate]?
        for key in candidateCacheKeys.reversed() {
            guard key.hasSuffix(keySuffix) else { continue }
            let segment = Self.cacheSegment(fromCacheKey: key)
            guard segment.count < hiragana.count, hiragana.hasPrefix(segment) else { continue }
            if let current = bestPrefix, segment.count <= current.count { continue }
            bestPrefix = segment
            bestCandidates = candidateCache[key]
        }
        if let segment = bestPrefix, let cached = bestCandidates {
            let texts = Self.candidateTexts(from: cached, inputLength: segment.count)
            guard !texts.isEmpty else { return nil }
            return AzooKeyCachePeek(candidates: texts, match: .prefix(sourceReading: segment))
        }
        return nil
    }

    public func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool = false) -> [String] {
        let key = Self.cacheKey(segment: hiragana, leftSideContext: leftSideContext, richCandidates: richCandidates)
        let inputLength = hiragana.count
        if let cached = candidateCache[key] {
            insertCache(key: key, value: cached)
            return Self.candidateTexts(from: cached, inputLength: inputLength)
        }
        var text = ComposingText()
        text.insertAtCursorPosition(hiragana, inputStyle: .direct)
        let options = makeOptions(leftSideContext: leftSideContext, richCandidates: richCandidates)
        return locked.withLock { c in
            os_signpost(.begin, log: spLog, name: "requestCandidates", "%{public}s", hiragana)
            let t0 = CFAbsoluteTimeGetCurrent()
            let result = c.requestCandidates(text, options: options)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            os_signpost(.end, log: spLog, name: "requestCandidates")
            os_log(.debug, log: spLog, "requestCandidates %.1fms %{public}s zenzai=%d", elapsedMs, hiragana, zenzaiEnabled ? 1 : 0)
            insertCache(key: key, value: result.mainResults)
            return Self.candidateTexts(from: result.mainResults, inputLength: inputLength)
        }
    }

    /// `requestCandidates` と同じキャッシュキーで、表示候補テキスト → 代表 `lcid` を返す。
    public func primaryLcidByText(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool = false
    ) -> [String: Int] {
        guard !hiragana.isEmpty else { return [:] }
        let key = Self.cacheKey(
            segment: hiragana,
            leftSideContext: leftSideContext,
            richCandidates: richCandidates
        )
        guard let cached = candidateCache[key] else { return [:] }
        return Self.primaryLcidMap(from: cached, inputLength: hiragana.count)
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
            let isHiragana = KanaUtils.isHiragana(scalar)
            let isKatakana = KanaUtils.isKatakana(scalar)
            guard isHiragana || isKatakana else { return true }
            return (147...554).contains(last.lcid)
        }
        return validCoverage.isEmpty ? predictionFiltered : validCoverage
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
