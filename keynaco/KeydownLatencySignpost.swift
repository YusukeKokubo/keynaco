import Foundation
import KeynacoCore
import os

/// keydown から候補ウィンドウ反映までの end-to-end 計測（Instruments Points of Interest）。
@MainActor
enum KeydownLatencySignpost {
    private static let log = OSLog(subsystem: "jp.leaner.keynaco", category: "Latency")

    private static let peekUpdateName: StaticString = "peekUpdate"
    private static let fetchCompleteName: StaticString = "fetchComplete"

    private static var openPeek: (generation: Int, id: OSSignpostID)?
    private static var openFetch: (generation: Int, id: OSSignpostID)?
    private static var peekStartTimes: [Int: ContinuousClock.Instant] = [:]
    private static var fetchStartTimes: [Int: ContinuousClock.Instant] = [:]

    static func onKeyDown(generation: Int) {
        closeOrphanedSignposts()
        let id = OSSignpostID(log: log)
        openPeek = (generation, id)
        peekStartTimes[generation] = ContinuousClock.now
        os_signpost(
            .begin,
            log: log,
            name: peekUpdateName,
            signpostID: id
        )
    }

    static func endPeekUpdate(generation: Int, stats: TypingLatencyStats) {
        guard let open = openPeek, open.generation == generation else { return }
        openPeek = nil
        os_signpost(
            .end,
            log: log,
            name: peekUpdateName,
            signpostID: open.id
        )
        if let start = peekStartTimes.removeValue(forKey: generation) {
            stats.recordPeekUpdate(ms: elapsedMs(since: start))
        }
    }

    static func beginFetchComplete(generation: Int) {
        let id = OSSignpostID(log: log)
        openFetch = (generation, id)
        fetchStartTimes[generation] = ContinuousClock.now
        os_signpost(
            .begin,
            log: log,
            name: fetchCompleteName,
            signpostID: id
        )
    }

    static func endFetchComplete(generation: Int, stats: TypingLatencyStats) {
        guard let open = openFetch, open.generation == generation else { return }
        openFetch = nil
        os_signpost(
            .end,
            log: log,
            name: fetchCompleteName,
            signpostID: open.id
        )
        if let start = fetchStartTimes.removeValue(forKey: generation) {
            stats.recordFetchComplete(ms: elapsedMs(since: start))
        }
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> Double {
        let delta = ContinuousClock.now - start
        let seconds = Double(delta.components.seconds)
        let attoseconds = Double(delta.components.attoseconds) / 1_000_000_000_000_000_000
        return (seconds + attoseconds) * 1_000
    }

    private static func closeOrphanedSignposts() {
        if let open = openPeek {
            openPeek = nil
            peekStartTimes.removeValue(forKey: open.generation)
            os_signpost(
                .end,
                log: log,
                name: peekUpdateName,
                signpostID: open.id
            )
        }
        if let open = openFetch {
            openFetch = nil
            fetchStartTimes.removeValue(forKey: open.generation)
            os_signpost(
                .end,
                log: log,
                name: fetchCompleteName,
                signpostID: open.id
            )
        }
    }
}
