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

    private(set) var candidateGeneration = 0
    private var pendingTask: Task<Void, Never>?
    private var lastKeyDownInstant: ContinuousClock.Instant?
    private(set) var lastInterKeyIntervalMs: Double?

    var hasPendingWork: Bool {
        guard let pendingTask else { return false }
        return !pendingTask.isCancelled
    }

    /// keyDown ごとに呼ぶ。直前タスクをキャンセルし、新しい generation を返す。
    @discardableResult
    func onKeyDown(converter: any AzooKeyConverting) -> Int {
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
        converter.setLiveGeneration(candidateGeneration)
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
        let engineReading = InputHandler.azooKeyReading(for: reading)
        _ = converter.requestCandidates(
            hiragana: engineReading,
            leftSideContext: leftSideContext,
            richCandidates: true,
            options: .default
        )
    }

    func schedule(
        generation: Int,
        reading: String,
        leftSideContext: String?,
        converter: any AzooKeyConverting,
        debounceNanoseconds: UInt64 = AzooKeyDebouncePolicy.defaultNanoseconds,
        onComplete: @escaping @MainActor ([AzooKeyCandidate]) -> Void
    ) {
        let isPaused = (lastInterKeyIntervalMs ?? 0) >= 160
        let inferenceLimit: Int? = isPaused ? nil : AzooKeyConverter.whileTypingInferenceLimit
        pendingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard candidateGeneration == generation else { return }

            let capturedReading = InputHandler.azooKeyReading(for: reading)
            let capturedContext = leftSideContext
            let fetchOptions = AzooKeyFetchOptions(zenzaiInferenceLimit: inferenceLimit)
            let outcome = await converter.requestCandidatesWhileTyping(
                generation: generation,
                hiragana: capturedReading,
                leftSideContext: capturedContext,
                options: fetchOptions
            )

            guard !Task.isCancelled else {
                if outcome.didRunFetch {
                    converter.latencyStats.recordWastedFetch()
                    converter.fetchLogger.markLastFetchWasted(matchingReading: capturedReading)
                }
                return
            }
            guard candidateGeneration == generation else {
                if outcome.didRunFetch {
                    converter.latencyStats.recordWastedFetch()
                    converter.fetchLogger.markLastFetchWasted(matchingReading: capturedReading)
                }
                return
            }
            switch outcome {
            case .abortedBeforeFetch:
                return
            case .wastedAfterFetch:
                converter.latencyStats.recordWastedFetch()
                converter.fetchLogger.markLastFetchWasted(matchingReading: capturedReading)
                return
            case .success(let candidates):
                pendingTask = nil
                onComplete(candidates)
            }
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
