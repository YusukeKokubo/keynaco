import Foundation
@testable import KeynacoCore

/// 候補リストスナップショット・inject 等価性テスト用 AzooKey スタブ。
final class SnapStub: BaseAzooKeyStub, @unchecked Sendable {
    let candidates: [AzooKeyCandidate]
    init(_ lines: [String], zenzai: Bool = false) {
        self.candidates = lines.map { AzooKeyCandidate.text($0) }
        super.init()
        isZenzaiEnabled = zenzai
    }
    init(candidates: [AzooKeyCandidate], zenzai: Bool = false) {
        self.candidates = candidates
        super.init()
        isZenzaiEnabled = zenzai
    }
    override func requestCandidates(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool,
        options: AzooKeyFetchOptions
    ) -> [AzooKeyCandidate] {
        candidates
    }
}
