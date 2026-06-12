public protocol AzooKeyConverting: AnyObject, Sendable {
    /// ユーザー設定の Zenzai 有効フラグ。モデルの実ロード状態は反映しない（ベストエフォート）。
    var isZenzaiEnabled: Bool { get }
    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String]
    /// `candidateCache` の同期参照。ヒット時は非同期取得を待たず候補に使える。
    func peekCachedCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> AzooKeyCachePeek?
    func commit(reading: String, text: String)
    /// 確定済み `(reading, output)` に対応する AzooKey 辞書エントリの代表 `lcid` を返す。
    func lcidForCommitted(reading: String, output: String) -> Int?
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
}

extension AzooKeyConverter: AzooKeyConverting {}
