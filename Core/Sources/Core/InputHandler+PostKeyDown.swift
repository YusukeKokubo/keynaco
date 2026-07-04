import Foundation

public extension InputHandler {

    /// sandbox: 候補 `applyCandidateAction` を適用。IMK キャッシュは更新しない。
    mutating func applyPostKeyDownCandidateAndIMK(
        action: CandidateAction,
        client: TextInputClient
    ) {
        applyCandidateAction(action, client: client)
    }

    /// 本番: 候補 apply と marked text 同期を `consumed` 不問で実行。`imkCache` をキー処理後のルールで更新する。
    ///
    /// `consumed` に関わらず常に `applyCandidateAction` を呼ぶことで、未消費キー後の marked text 同期漏れを防ぐ。
    /// `action == .none` のときは candidateSession は変わらず `syncMarkedText` のみ走る（冪等）。
    mutating func applyPostKeyDownCandidateAndIMK(
        consumed: Bool,
        action: CandidateAction,
        client: TextInputClient,
        composedHiraganaWasEmpty: Bool,
        didInsertText: Bool,
        imkCache: inout LeftContextIMKCache,
        newIMKSnapshot: IMKSurroundingSnapshot?
    ) {
        applyCandidateAction(action, client: client)
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
            || cache.isInvalidated
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
