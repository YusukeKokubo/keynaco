import Foundation
import KeynacoCore

/// `.whileTyping` の AzooKey 取得を debounce 付きで背景実行する。`InputController` と Debug ソケットが共有。
///
/// Phase 3: `richCandidates: true` で先読みし Space（`.explicit`）のキャッシュヒットを狙う。
/// debounce 間隔は `AzooKeyDebouncePolicy` で打鍵速度・`pendingRomaji` に応じて 40–120ms。
@MainActor
final class AzooKeyAsyncScheduler {
    /// 後方互換・テスト用の固定 debounce（ポリシー未指定時のフォールバック）。
    static let debounceNanoseconds: UInt64 = AzooKeyDebouncePolicy.defaultNanoseconds

    /// `Task.detached` から generation を読むためのスレッドセーフミラー。
    private final class LockedGeneration: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func set(_ v: Int) { lock.withLock { value = v } }
        func get() -> Int { lock.withLock { value } }
    }

    private(set) var candidateGeneration = 0
    private let liveGeneration = LockedGeneration()
    private var pendingTask: Task<Void, Never>?
    private var lastKeyDownInstant: ContinuousClock.Instant?
    private(set) var lastInterKeyIntervalMs: Double?

    var hasPendingWork: Bool {
        guard let pendingTask else { return false }
        return !pendingTask.isCancelled
    }

    /// keyDown ごとに呼ぶ。直前タスクをキャンセルし、新しい generation を返す。
    @discardableResult
    func onKeyDown() -> Int {
        let now = ContinuousClock.now
        if let previous = lastKeyDownInstant {
            let delta = now - previous
            let seconds = Double(delta.components.seconds)
            let attoseconds = Double(delta.components.attoseconds) / 1_000_000_000_000_000_000
            lastInterKeyIntervalMs = (seconds + attoseconds) * 1_000
        } else {
            lastInterKeyIntervalMs = nil
        }
        lastKeyDownInstant = now

        candidateGeneration += 1
        liveGeneration.set(candidateGeneration)
        cancelPendingWork()
        return candidateGeneration
    }

    func cancelPendingWork() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    /// Space 等の明示変換直前に呼ぶ。debounce 中の prefetch を止め、rich キャッシュを同期で温める。
    /// 走行中の detached 呼び出しがあれば `AzooKeyConverter` の Lock で直列待ちする。
    func warmRichCacheForExplicit(
        reading: String,
        leftSideContext: String?,
        converter: any AzooKeyConverting
    ) {
        cancelPendingWork()
        guard !reading.isEmpty, !reading.allSatisfy(\.isASCII) else { return }
        _ = converter.requestCandidates(
            hiragana: reading,
            leftSideContext: leftSideContext,
            richCandidates: true
        )
    }

    func schedule(
        generation: Int,
        reading: String,
        leftSideContext: String?,
        converter: any AzooKeyConverting,
        debounceNanoseconds: UInt64 = AzooKeyDebouncePolicy.defaultNanoseconds,
        onComplete: @escaping @MainActor ([String]) -> Void
    ) {
        pendingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard candidateGeneration == generation else { return }

            let capturedReading = reading
            let capturedContext = leftSideContext
            let conv = converter
            let genSnapshot = generation
            let liveGen = liveGeneration

            let candidates = await Task.detached {
                guard liveGen.get() == genSnapshot else { return [String]() }
                return conv.requestCandidates(
                    hiragana: capturedReading,
                    leftSideContext: capturedContext,
                    richCandidates: true
                )
            }.value

            guard !Task.isCancelled else { return }
            guard candidateGeneration == generation else { return }
            pendingTask = nil
            onComplete(candidates)
        }
    }

    /// pending が解消するまで待つ。タイムアウト時は `false`。
    func waitUntilIdle(timeoutNanoseconds: UInt64 = 2_000_000_000) async -> Bool {
        let step: UInt64 = 10_000_000
        var elapsed: UInt64 = 0
        while hasPendingWork, elapsed < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: step)
            elapsed += step
        }
        return !hasPendingWork
    }
}
