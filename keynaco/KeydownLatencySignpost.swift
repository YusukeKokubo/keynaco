import Foundation
import os

/// keydown から候補ウィンドウ反映までの end-to-end 計測（Instruments Points of Interest）。
@MainActor
enum KeydownLatencySignpost {
    private static let log = OSLog(subsystem: "jp.leaner.keynaco", category: "Latency")

    private static let peekUpdateName: StaticString = "peekUpdate"
    private static let fetchCompleteName: StaticString = "fetchComplete"

    private static var openPeek: (generation: Int, id: OSSignpostID)?
    private static var openFetch: (generation: Int, id: OSSignpostID)?

    static func onKeyDown(generation: Int) {
        closeOrphanedSignposts()
        let id = OSSignpostID(log: log)
        openPeek = (generation, id)
        os_signpost(
            .begin,
            log: log,
            name: peekUpdateName,
            signpostID: id
        )
    }

    static func endPeekUpdate(generation: Int) {
        guard let open = openPeek, open.generation == generation else { return }
        openPeek = nil
        os_signpost(
            .end,
            log: log,
            name: peekUpdateName,
            signpostID: open.id
        )
    }

    static func beginFetchComplete(generation: Int) {
        let id = OSSignpostID(log: log)
        openFetch = (generation, id)
        os_signpost(
            .begin,
            log: log,
            name: fetchCompleteName,
            signpostID: id
        )
    }

    static func endFetchComplete(generation: Int) {
        guard let open = openFetch, open.generation == generation else { return }
        openFetch = nil
        os_signpost(
            .end,
            log: log,
            name: fetchCompleteName,
            signpostID: open.id
        )
    }

    private static func closeOrphanedSignposts() {
        if let open = openPeek {
            openPeek = nil
            os_signpost(
                .end,
                log: log,
                name: peekUpdateName,
                signpostID: open.id
            )
        }
        if let open = openFetch {
            openFetch = nil
            os_signpost(
                .end,
                log: log,
                name: fetchCompleteName,
                signpostID: open.id
            )
        }
    }
}
