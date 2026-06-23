#if DEBUG

import Foundation

public struct InputHandlerSnapshot: Sendable {
    public var composedHiragana: String
    public var pendingRomaji: String
    public var composingText: String
    public var markedText: String

    public var isAsciiMode: Bool
    public var isBracketMode: Bool
    public var isExplicitlySelected: Bool

    public var candidateVisible: Bool
    public var selectedRow: Int
    public var selectedText: String?
    public var fixedEnd: Int
    public var candidates: [String]

    public var committedHistory: [String]
    public var sessionTextBuffer: String

    public var candidateBuild: CandidateBuildDiagnostics?
}

#endif
