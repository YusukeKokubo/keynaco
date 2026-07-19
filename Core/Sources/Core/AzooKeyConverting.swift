public protocol AzooKeyConverting: AnyObject, Sendable {
    /// ユーザー設定の Zenzai 有効フラグ。モデルの実ロード状態は反映しない（ベストエフォート）。
    var isZenzaiEnabled: Bool { get }
    /// 打鍵レイテンシ計測（`AzooKeyConverter` のみ実値。スタブは独立インスタンス）。
    var latencyStats: TypingLatencyStats { get }
    /// fetch ごとの詳細ログ（`AzooKeyConverter` のみ実書き込み。スタブは no-op）。
    var fetchLogger: FetchLogger { get }
    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool, options: AzooKeyFetchOptions) -> [AzooKeyCandidate]
    /// whileTyping 非同期経路用。世代不一致なら fetch 前後で打ち切る。
    func requestCandidatesWhileTyping(
        generation: Int,
        hiragana: String,
        leftSideContext: String?,
        options: AzooKeyFetchOptions
    ) async -> FetchRequestOutcome
    /// `AzooKeyAsyncScheduler.onKeyDown` から呼ぶ live generation の正本。
    func setLiveGeneration(_ generation: Int)
    /// `candidateCache` の同期参照。ヒット時は非同期取得を待たず候補に使える。
    func peekCachedCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> AzooKeyCachePeek?
    func commit(reading: String, text: String)
    /// 確定済み `(reading, output)` に対応する AzooKey 辞書エントリの代表 `lcid` を返す。
    func lcidForCommitted(reading: String, output: String) -> Int?
    /// キャッシュから候補の canonical reading（ruby 連結）を返す。キャッシュミスの場合は nil。
    func canonicalReading(for reading: String, text: String) -> String?
}

extension AzooKeyConverting {
    var isZenzaiEnabled: Bool { false }
    /// テスト stub 向け no-op 共有インスタンス。`appVersion` セット等を安全に流せるが書き込みは行わない
    /// （`FetchLogger.flushForced` を呼ばない限りディスクには出ない）。
    var fetchLogger: FetchLogger { FetchLogger.sharedNoOp }

    func requestCandidatesWhileTyping(
        generation: Int,
        hiragana: String,
        leftSideContext: String?,
        options: AzooKeyFetchOptions
    ) async -> FetchRequestOutcome {
        let candidates = requestCandidates(
            hiragana: hiragana,
            leftSideContext: leftSideContext,
            richCandidates: true,
            options: options
        )
        return .success(candidates)
    }

    func setLiveGeneration(_ generation: Int) { _ = generation }

    func requestCandidates(hiragana: String) -> [AzooKeyCandidate] {
        requestCandidates(hiragana: hiragana, leftSideContext: nil, richCandidates: false, options: .default)
    }

    func requestCandidates(hiragana: String, leftSideContext: String?) -> [AzooKeyCandidate] {
        requestCandidates(hiragana: hiragana, leftSideContext: leftSideContext, richCandidates: false, options: .default)
    }

    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [AzooKeyCandidate] {
        requestCandidates(hiragana: hiragana, leftSideContext: leftSideContext, richCandidates: richCandidates, options: .default)
    }

    func peekCachedCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> AzooKeyCachePeek? {
        nil
    }

    func lcidForCommitted(reading: String, output: String) -> Int? { nil }

    func canonicalReading(for reading: String, text: String) -> String? { nil }
}

extension AzooKeyConverter: AzooKeyConverting {}
