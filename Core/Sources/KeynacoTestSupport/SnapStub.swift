import Foundation
@testable import KeynacoCore

/// 候補リストスナップショット・inject 等価性テスト用 AzooKey スタブ。
final class SnapStub: BaseAzooKeyStub, @unchecked Sendable {
    let lines: [String]
    init(_ lines: [String], zenzai: Bool = false) {
        self.lines = lines
        super.init()
        isZenzaiEnabled = zenzai
    }
    override func requestCandidates(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool,
        options: AzooKeyFetchOptions
    ) -> [AzooKeyCandidate] {
        lines.map { AzooKeyCandidate.text($0) }
    }
}
