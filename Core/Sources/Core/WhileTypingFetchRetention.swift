import Foundation

/// keyDown 後に、予約中（debounce 中 or 走行中）の whileTyping fetch を生かすかどうかの判定。
///
/// ローマ字入力では読みが変わるのは母音キー等だけで、間の子音キー（`k` 等）は `pendingRomaji` を伸ばすだけ。
/// 以前は全 keyDown で世代を進めとったため、子音キーのたびに同じ読みの fetch を捨てとった（PLAN260929a）。
/// 読み・左文脈が予約時と同一で、新たに別読みの fetch を要求しとらんときだけ世代を据え置く。
/// 適用時は `AsyncCandidateArrival.shouldApply` が読み一致・explicit・組成中を改めて確認する。
public enum WhileTypingFetchRetention {
    public struct Input: Equatable, Sendable {
        /// スケジューラが保持中の fetch の読み。保持中の fetch がなければ `nil`。
        public let pendingReading: String?
        public let pendingLeftContext: String?
        public let composedHiraganaBefore: String
        public let composedHiraganaAfter: String
        public let leftContextAfter: String?
        /// keyDown 後に `InputHandler` が要求した fetch 読み（`pendingAzooKeyReading`）。
        public let requestedReading: String?
        public let consumed: Bool

        public init(
            pendingReading: String?,
            pendingLeftContext: String?,
            composedHiraganaBefore: String,
            composedHiraganaAfter: String,
            leftContextAfter: String?,
            requestedReading: String?,
            consumed: Bool
        ) {
            self.pendingReading = pendingReading
            self.pendingLeftContext = pendingLeftContext
            self.composedHiraganaBefore = composedHiraganaBefore
            self.composedHiraganaAfter = composedHiraganaAfter
            self.leftContextAfter = leftContextAfter
            self.requestedReading = requestedReading
            self.consumed = consumed
        }
    }

    public static func shouldKeepPending(_ input: Input) -> Bool {
        guard input.consumed, let pending = input.pendingReading else { return false }
        guard input.composedHiraganaBefore == pending,
              input.composedHiraganaAfter == pending else { return false }
        guard input.leftContextAfter == input.pendingLeftContext else { return false }
        if let requested = input.requestedReading, requested != pending { return false }
        return true
    }
}
