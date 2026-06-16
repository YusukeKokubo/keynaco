public protocol AzooKeyConverting: AnyObject, Sendable {
    /// ユーザー設定の Zenzai 有効フラグ。モデルの実ロード状態は反映しない（ベストエフォート）。
    var isZenzaiEnabled: Bool { get }
    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String]
    /// `candidateCache` の同期参照。ヒット時は非同期取得を待たず候補に使える。
    func peekCachedCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> AzooKeyCachePeek?
    func commit(reading: String, text: String)
    /// 確定済み `(reading, output)` に対応する AzooKey 辞書エントリの代表 `lcid` を返す。
    func lcidForCommitted(reading: String, output: String) -> Int?
    /// `requestCandidates` 直後の `candidateCache` から、表示候補テキスト → 代表 `lcid` を返す（変換は再実行しない）。
    func primaryLcidByText(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String: Int]
    /// キャッシュから候補の canonical reading（ruby 連結）を返す。キャッシュミスの場合は nil。
    func canonicalReading(for reading: String, text: String) -> String?
}

extension AzooKeyConverting {
    var isZenzaiEnabled: Bool { false }

    func requestCandidates(hiragana: String) -> [String] {
        requestCandidates(hiragana: hiragana, leftSideContext: nil, richCandidates: false)
    }

    func requestCandidates(hiragana: String, leftSideContext: String?) -> [String] {
        requestCandidates(hiragana: hiragana, leftSideContext: leftSideContext, richCandidates: false)
    }

    func peekCachedCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> AzooKeyCachePeek? {
        nil
    }

    func lcidForCommitted(reading: String, output: String) -> Int? { nil }

    func primaryLcidByText(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String: Int] {
        _ = (hiragana, leftSideContext, richCandidates)
        return [:]
    }

    func canonicalReading(for reading: String, text: String) -> String? { nil }
}

extension AzooKeyConverter: AzooKeyConverting {}
