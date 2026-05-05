public protocol AzooKeyConverting: AnyObject, Sendable {
    func requestCandidates(hiragana: String, leftSideContext: String?) -> [String]
    func candidatesForSegment(reading: String, leftSideContext: String?) -> [String]
    func commit(reading: String, text: String)
    func segmentize(_ hiragana: String, leftSideContext: String?) -> [(reading: String, candidates: [String])]
}

public extension AzooKeyConverting {
    func requestCandidates(hiragana: String) -> [String] {
        requestCandidates(hiragana: hiragana, leftSideContext: nil)
    }

    func candidatesForSegment(reading: String) -> [String] {
        candidatesForSegment(reading: reading, leftSideContext: nil)
    }

    func segmentize(_ hiragana: String) -> [(reading: String, candidates: [String])] {
        segmentize(hiragana, leftSideContext: nil)
    }
}

extension AzooKeyConverter: AzooKeyConverting {}
