public protocol AzooKeyConverting: AnyObject, Sendable {
    /// ユーザー設定の Zenzai 有効フラグ。モデルの実ロード状態は反映しない（ベストエフォート）。
    var isZenzaiEnabled: Bool { get }
    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String]
    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String]
    func commit(reading: String, text: String)
    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])]
    /// 確定済み `(reading, output)` に対応する AzooKey 辞書エントリの代表 `lcid` を返す。
    func lcidForCommitted(reading: String, output: String) -> Int?
}

public extension AzooKeyConverting {
    var isZenzaiEnabled: Bool { false }

    func requestCandidates(hiragana: String) -> [String] {
        requestCandidates(hiragana: hiragana, leftSideContext: nil, richCandidates: false)
    }

    func requestCandidates(hiragana: String, leftSideContext: String?) -> [String] {
        requestCandidates(hiragana: hiragana, leftSideContext: leftSideContext, richCandidates: false)
    }

    func candidatesForSegment(reading: String) -> [String] {
        candidatesForSegment(reading: reading, leftSideContext: nil)
    }

    func segmentize(_ hiragana: String) -> [(reading: String, candidates: [String])] {
        segmentize(hiragana, leftSideContext: nil)
    }

    func lcidForCommitted(reading: String, output: String) -> Int? { nil }
}

extension AzooKeyConverter: AzooKeyConverting {}
