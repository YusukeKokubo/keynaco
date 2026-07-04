import AppKit
import Foundation

/// `runKeyDown` / sandbox `handleKeyEvent` / benchmark 共通の keyDown 手順。
public enum KeyEventPipeline {
    public struct PreSnapshot: Sendable {
        public let composedHiraganaWasEmpty: Bool
        public let candidate: CandidateContext

        public init(composedHiraganaWasEmpty: Bool, candidate: CandidateContext) {
            self.composedHiraganaWasEmpty = composedHiraganaWasEmpty
            self.candidate = candidate
        }
    }

    public struct HandleResult: Sendable {
        public let consumed: Bool
        public let candidateAction: CandidateAction
        public let composedHiraganaWasEmpty: Bool

        public init(consumed: Bool, candidateAction: CandidateAction, composedHiraganaWasEmpty: Bool) {
            self.consumed = consumed
            self.candidateAction = candidateAction
            self.composedHiraganaWasEmpty = composedHiraganaWasEmpty
        }
    }

    public struct PendingLogs: Sendable {
        public let sessionRecord: InputSessionRecord?
        public let divergenceRecord: CandidateDivergenceRecord?

        public init(
            sessionRecord: InputSessionRecord?,
            divergenceRecord: CandidateDivergenceRecord?
        ) {
            self.sessionRecord = sessionRecord
            self.divergenceRecord = divergenceRecord
        }
    }

    public static func preSnapshot(handler: InputHandler) -> PreSnapshot {
        PreSnapshot(
            composedHiraganaWasEmpty: handler.state.composedHiragana.isEmpty,
            candidate: handler.candidateSession.makeContext()
        )
    }

    /// pre スナップショット → `handle()`。pre/post の読み分けは呼び出し側が `preSnapshot` 時点で固定する。
    public static func runHandle(
        handler: inout InputHandler,
        keyCode: UInt16,
        characters: String?,
        baseCharacters: String?,
        modifiers: NSEvent.ModifierFlags,
        pre: PreSnapshot,
        client: TextInputClient
    ) -> HandleResult {
        let (consumed, action) = handler.handle(
            keyCode: keyCode,
            characters: characters,
            baseCharacters: baseCharacters,
            modifiers: modifiers,
            candidate: pre.candidate,
            client: client
        )
        return HandleResult(
            consumed: consumed,
            candidateAction: action,
            composedHiraganaWasEmpty: pre.composedHiraganaWasEmpty
        )
    }

    /// `commitComposition` / `doEscape` が書いた pending レコードを取り出す。
    public static func drainPendingLogs(from handler: inout InputHandler) -> PendingLogs {
        let logs = PendingLogs(
            sessionRecord: handler.pendingSessionRecord,
            divergenceRecord: handler.pendingDivergenceRecord
        )
        handler.pendingSessionRecord = nil
        handler.pendingDivergenceRecord = nil
        return logs
    }
}
