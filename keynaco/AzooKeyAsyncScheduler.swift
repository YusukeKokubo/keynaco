import Foundation
import KeynacoCore

/// `.whileTyping` の AzooKey 取得を debounce 付きで背景実行する。`InputController` と Debug ソケットが共有。
@MainActor
final class AzooKeyAsyncScheduler {
    static let debounceNanoseconds: UInt64 = 70_000_000

    private(set) var candidateGeneration = 0
    private var pendingTask: Task<Void, Never>?

    var hasPendingWork: Bool {
        guard let pendingTask else { return false }
        return !pendingTask.isCancelled
    }

    /// keyDown ごとに呼ぶ。直前タスクをキャンセルし、新しい generation を返す。
    @discardableResult
    func onKeyDown() -> Int {
        candidateGeneration += 1
        cancelPendingWork()
        return candidateGeneration
    }

    func cancelPendingWork() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    func schedule(
        generation: Int,
        reading: String,
        leftSideContext: String?,
        converter: any AzooKeyConverting,
        onComplete: @escaping @MainActor ([String]) -> Void
    ) {
        pendingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard candidateGeneration == generation else { return }

            let capturedReading = reading
            let capturedContext = leftSideContext
            let conv = converter

            let candidates = await Task.detached {
                conv.requestCandidates(
                    hiragana: capturedReading,
                    leftSideContext: capturedContext,
                    richCandidates: false
                )
            }.value

            guard !Task.isCancelled else { return }
            guard candidateGeneration == generation else { return }
            onComplete(candidates)
            pendingTask = nil
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
