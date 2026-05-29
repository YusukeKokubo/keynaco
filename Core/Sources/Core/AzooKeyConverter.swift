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
            // 組成中の予測補完。完成形・活用形（ありがとう/おはよう/考える等）を候補に追加する。
            // 予測候補は composingCount==inputLength でカバレッジフィルタ（requestCandidates）を通り、
            // dictionary セクション（固定枠・履歴の下）に流れ込むため候補順序を壊さない。
            // 価値はコールドスタート補完（履歴のない語の穴埋め）。履歴の代替ではなく補完。
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
        let key = Self.cacheKey(segment: hiragana, leftSideContext: leftSideContext)
        var text = ComposingText()
        text.insertAtCursorPosition(hiragana, inputStyle: .direct)
        let result = locked.withLock { c in
            let r = c.requestCandidates(text, options: makeOptions(leftSideContext: leftSideContext, richCandidates: richCandidates))
            insertCache(key: key, value: r.mainResults)
            return r
        }
        let inputLength = hiragana.count
        let fullCoverage = result.mainResults.filter { composingCountValue($0) == inputLength }
        // 末尾 data エントリが1文字のひらがな/カタカナである複合変換候補を除外する
        // （例: 「蛇あ」= 蛇(じゃ)+あ → "あ"が1文字ひらがなで残余とみなす）
        // 末尾 data エントリが1文字のひらがな/カタカナである複合変換候補を除外する。
        // ただし末尾が助詞(lcid 147...368)または助動詞(lcid 369...554)として変換済みの場合は除外しない。
        // 残余判定: 末尾が1文字かな かつ 助詞/助動詞でない → 未変換の残余（例: 「蛇あ」の"あ"）
        // 変換済み判定: 末尾が助詞/助動詞 → 正当な変換（例: 「学んだか」の"か"、「学んだ」の"だ"）
        let validCoverage = fullCoverage.filter { c in
            guard c.data.count > 1, let last = c.data.last else { return true }
            guard last.word.count == 1, let scalar = last.word.unicodeScalars.first else { return true }
            let isHiragana = (0x3041...0x3096).contains(scalar.value)
            let isKatakana = (0x30A1...0x30F6).contains(scalar.value)
            guard isHiragana || isKatakana else { return true }
            return (147...554).contains(last.lcid)
        }
        let preferred = validCoverage.isEmpty ? fullCoverage : validCoverage
        return (preferred.isEmpty ? result.mainResults : preferred).map { $0.text }
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
