import Foundation

public extension InputHandler {

    /// キー処理直後の共通副作用: 候補 `applyCandidateAction`、本番時は IMK キャッシュ更新。
    ///
    /// - Parameter alwaysApplyCandidateAction: sandbox は `true`。本番 `InputController` は `false`（`consumed` 時のみ）。
    /// - Parameter imkCache: 本番は `&leftContextIMKCache`。sandbox は `nil` で IMK 経路をスキップ。
    mutating func applyPostKeyDownEffects(
        consumed: Bool,
        action: CandidateAction,
        client: TextInputClient,
        composedHiraganaWasEmpty: Bool,
        didInsertText: Bool,
        alwaysApplyCandidateAction: Bool,
        imkCache: inout LeftContextIMKCache?,
        newIMKSnapshot: IMKSurroundingSnapshot?
    ) {
        if alwaysApplyCandidateAction || consumed {
            applyCandidateAction(action, client: client)
        }

        guard var cache = imkCache else { return }

        let needsIMKMaintenance = consumed
            || cache.invalidated
            || didInsertText
            || (composedHiraganaWasEmpty && !state.composedHiragana.isEmpty)

        guard needsIMKMaintenance else { return }

        LeftContextSource.applyPostKeyDown(
            cache: &cache,
            composedHiraganaEmpty: state.composedHiragana.isEmpty,
            composedHiraganaWasEmpty: composedHiraganaWasEmpty,
            newSnapshot: newIMKSnapshot
        )
        imkCache = cache
    }
}
