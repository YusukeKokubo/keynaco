public protocol AzooKeyConverting: AnyObject, Sendable {
    func requestCandidates(hiragana: String) -> [String]
    func candidatesForSegment(reading: String) -> [String]
    func commit(reading: String, text: String)
    func segmentize(_ hiragana: String) -> [(reading: String, candidates: [String])]
}

extension AzooKeyConverter: AzooKeyConverting {}
