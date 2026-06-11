import Foundation

public extension InputHandler {

    /// sandbox: 候補 `applyCandidateAction` を consumed 不問で適用。IMK キャッシュは更新しない。
    mutating func applyPostKeyDownCandidateAndIMK(
        consumed: Bool,
        action: CandidateAction,
        client: TextInputClient,
        composedHiraganaWasEmpty: Bool,
        didInsertText: Bool
    ) {
        applyCandidateAction(action, client: client)
    }

    /// 本番: `consumed` 時のみ候補 apply。`imkCache` をキー処理後のルールで更新する。
    mutating func applyPostKeyDownCandidateAndIMK(
        consumed: Bool,
        action: CandidateAction,
        client: TextInputClient,
        composedHiraganaWasEmpty: Bool,
        didInsertText: Bool,
        imkCache: inout LeftContextIMKCache,
        newIMKSnapshot: IMKSurroundingSnapshot?
    ) {
        if consumed {
            applyCandidateAction(action, client: client)
        }
        maintainIMKCacheAfterKeyDown(
            consumed: consumed,
            composedHiraganaWasEmpty: composedHiraganaWasEmpty,
            didInsertText: didInsertText,
            cache: &imkCache,
            newIMKSnapshot: newIMKSnapshot
        )
    }

    private mutating func maintainIMKCacheAfterKeyDown(
        consumed: Bool,
        composedHiraganaWasEmpty: Bool,
        didInsertText: Bool,
        cache: inout LeftContextIMKCache,
        newIMKSnapshot: IMKSurroundingSnapshot?
    ) {
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
    }
}
