#if DEBUG

import Foundation
import Darwin
import AppKit
import SQLite3

// MARK: - Unix ドメインソケットサーバー

/// キー入力コマンドを受け取り、専用 `InputHandler` で処理して JSON で返すデバッグサーバー。
/// IMK パイプラインをバイパスするため、アプリごとの互換性問題は再現しない。
/// `InputHandler` のロジックデバッグを対話的に行うためのもの。
@MainActor
final class DebugSocketServer: @unchecked Sendable {
    static let shared = DebugSocketServer()

    static var socketPath: String {
        (ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp")
            .appending("keynaco-debug.sock")
    }

    private var serverFd: Int32 = -1
    private var handler = InputHandler(db: DatabaseManager(inMemory: true, seedPresets: true))
    private let mockClient = SocketMockClient()
    private var candidateWindow = DebugCandidateWindow()

    private let successorLLM = LLMSuccessorFetcher()
    private let segmentLLM = LLMSegmentConverter()
    private let candidateScorer = LLMCandidateScorer()

    /// `deinit` から参照するため `nonisolated(unsafe)`。書き込みは MainActor のみ。
    nonisolated(unsafe) private var snapshotURL: URL?

    private init() {}

    deinit {
        Self.removeSnapshotArtifacts(baseURL: snapshotURL)
    }

    func start() {
        let path = Self.socketPath
        unlink(path)

        serverFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.withCString { src in
                buf.baseAddress!.copyMemory(from: src, byteCount: min(strlen(src) + 1, buf.count))
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { Darwin.close(serverFd); serverFd = -1; return }
        Darwin.listen(serverFd, 5)

        NSLog("[DebugSocketServer] listening at %@", path)
        let fd = serverFd
        Task.detached { [self] in await self.acceptLoop(serverFd: fd) }
    }

    func stop() {
        if serverFd >= 0 { Darwin.close(serverFd); serverFd = -1 }
        unlink(Self.socketPath)
    }

    // MARK: - I/O ループ（nonisolated: MainActor 外で動く）

    nonisolated func acceptLoop(serverFd: Int32) async {
        while true {
            let clientFd = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    cont.resume(returning: Darwin.accept(serverFd, nil, nil))
                }
            }
            if clientFd < 0 { return }
            Task.detached { [self] in await self.clientLoop(fd: clientFd) }
        }
    }

    nonisolated func clientLoop(fd: Int32) async {
        var buffer = Data()
        defer { Darwin.close(fd) }

        while true {
            let chunk = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                    let n = Darwin.recv(fd, ptr, 4096, 0)
                    let data: Data? = n > 0 ? Data(bytes: ptr, count: n) : nil
                    ptr.deallocate()
                    cont.resume(returning: data)
                }
            }
            guard let chunk else { return }
            buffer.append(chunk)

            while let nlIdx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = Data(buffer[buffer.startIndex..<nlIdx])
                buffer.removeSubrange(buffer.startIndex...nlIdx)
                guard !lineData.isEmpty else { continue }

                // Data（Sendable）を MainActor に渡し、String（Sendable）を受け取る
                let responseJSON = await MainActor.run { [self] in
                    self.processAndSerialize(lineData)
                }

                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .utility).async {
                        var out = Data(responseJSON.utf8)
                        out.append(UInt8(ascii: "\n"))
                        out.withUnsafeBytes { _ = Darwin.send(fd, $0.baseAddress!, $0.count, 0) }
                        cont.resume()
                    }
                }
            }
        }
    }

    // MARK: - コマンド処理（MainActor 上で実行）

    private func processAndSerialize(_ lineData: Data) -> String {
        let cmd = (try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]) ?? [:]
        let dict = processCommand(cmd)
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return #"{"error":"serialization"}"# }
        return str
    }

    private func processCommand(_ cmd: [String: Any]) -> [String: Any] {
        if cmd["reset"] != nil {
            cleanupSnapshot()
            successorLLM.cancel()
            segmentLLM.cancel()
            candidateScorer.cancel()
            handler.resetScorerPending()
            let useRealDB = cmd["useRealDB"] as? Bool ?? false
            if useRealDB, let db = makeRealDBSnapshot() {
                handler = InputHandler(db: db)
            } else {
                handler = InputHandler(db: DatabaseManager(inMemory: true, seedPresets: true))
            }
            InputHandler.isAsciiMode = false
            candidateWindow = DebugCandidateWindow()
            mockClient.reset()
            return ["ok": true]
        }

        if cmd["state"] != nil {
            return makeResponse(inserted: [])
        }

        let keyCode: UInt16
        switch cmd["keyCode"] {
        case let kc as UInt16: keyCode = kc
        case let kc as Int:    keyCode = UInt16(kc)
        default: return ["error": "missing keyCode"]
        }

        let chars = cmd["chars"] as? String
        let base  = cmd["base"]  as? String ?? chars
        let mods  = NSEvent.ModifierFlags(rawValue: (cmd["mods"] as? UInt) ?? 0)

        let (_, action) = handler.handle(
            keyCode: keyCode,
            characters: chars,
            baseCharacters: base,
            modifiers: mods,
            candidate: candidateWindow.context,
            client: mockClient
        )
        candidateWindow.apply(action: action)
        applyLLMScheduling()

        return makeResponse(inserted: mockClient.consume())
    }

    private func makeResponse(inserted: [String]) -> [String: Any] {
        var snap = handler.snapshot(markedText: mockClient.markedText)
        snap.candidateVisible   = candidateWindow.isVisible
        snap.selectedRow        = candidateWindow.selectedRow
        snap.selectedText       = candidateWindow.selectedText
        snap.isExplicitlySelected = candidateWindow.isExplicitlySelected
        snap.historyEnd         = candidateWindow.historyEnd
        snap.fixedEnd           = candidateWindow.fixedEnd
        snap.candidates         = candidateWindow.candidates

        var dict: [String: Any] = [
            "inserted":           inserted,
            "markedText":         snap.markedText,
            "composedHiragana":   snap.composedHiragana,
            "pendingRomaji":      snap.pendingRomaji,
            "composingText":      snap.composingText,
            "isAsciiMode":        snap.isAsciiMode,
            "isSuccessorMode":    snap.isSuccessorMode,
            "isSegmentMode":      snap.isSegmentMode,
            "isBracketMode":      snap.isBracketMode,
            "isExplicitlySelected": snap.isExplicitlySelected,
            "candidateVisible":   snap.candidateVisible,
            "selectedRow":        snap.selectedRow,
            "historyEnd":         snap.historyEnd,
            "predictionEnd":      candidateWindow.predictionEnd,
            "fixedEnd":           snap.fixedEnd,
            "candidates":         snap.candidates,
            "committedHistory":   snap.committedHistory,
            "segmentTexts":       snap.segmentTexts,
            "focusedSegmentIndex": snap.focusedSegmentIndex,
            "successorLLMSurfaceExtras": handler.successorLLMSurfaceExtras,
        ]
        if let st = snap.selectedText { dict["selectedText"] = st }
        return dict
    }

    // MARK: - LLM スケジューリング（InputController と同順・文脈は committedHistory のみ）

    private func llmDocumentContextPrefix() -> String {
        handler.committedHistory.suffix(5).joined()
    }

    private func applyLLMScheduling() {
        applySuccessorLLMScheduling()
        applySegmentLLMScheduling()
        applyCandidateScorerScheduling()
    }

    private func applySuccessorLLMScheduling() {
        let trigger = handler.successorLLMTrigger
        guard trigger != .none else { return }
        handler.successorLLMTrigger = .none

        let triggerContextOpt: [String]? = {
            switch trigger {
            case .pendingLowConfidence(let ctx), .particlesOnly(let ctx): return ctx
            case .none: return nil
            }
        }()
        let examples: [(prev: String, next: String)] = triggerContextOpt.flatMap { tc in
            tc.last.map { lw in
                handler.db.fetchBigramTop(prev: lw, limit: 5)
                    .filter { !InputHandler.particles.contains($0) }
                    .map { (prev: lw, next: $0) }
            }
        } ?? []

        let docPrefix = llmDocumentContextPrefix()

        switch trigger {
        case .none:
            break
        case .pendingLowConfidence(let triggerContext):
            successorLLM.fetch(
                context: triggerContext, documentContextPrefix: docPrefix, examples: examples
            ) { [weak self] words in
                guard let self else { return }
                guard Array(self.handler.committedHistory.suffix(3)) == triggerContext else { return }
                guard self.handler.isSuccessorMode else { return }
                var seen = Set(self.handler.pendingSuccessorCandidates)
                seen.formUnion(self.handler.successorLLMSurfaceExtras)
                let extra = words.filter { !seen.contains($0) }
                guard !extra.isEmpty else { return }
                self.handler.successorLLMSurfaceExtras.append(contentsOf: extra)
            }
        case .particlesOnly(let triggerContext):
            successorLLM.fetch(
                context: triggerContext, documentContextPrefix: docPrefix, examples: examples
            ) { [weak self] words in
                guard let self else { return }
                guard Array(self.handler.committedHistory.suffix(3)) == triggerContext else { return }
                guard self.handler.isSuccessorMode,
                      self.candidateWindow.isVisible,
                      let base = self.handler.successorLLMBaseCandidates else { return }
                var seen = Set(base)
                seen.formUnion(self.handler.successorLLMSurfaceExtras)
                let extra = words.filter { !seen.contains($0) }
                guard !extra.isEmpty else { return }
                for w in extra where seen.insert(w).inserted {
                    self.handler.successorLLMSurfaceExtras.append(w)
                }
                var merged = base
                var tailSeen = Set(base)
                for w in self.handler.successorLLMSurfaceExtras where tailSeen.insert(w).inserted {
                    merged.append(w)
                }
                let rowCap = max(0, merged.count - 1)
                let initialRow = min(self.candidateWindow.selectedRow, rowCap)
                self.candidateWindow.apply(
                    action: .show(
                        candidates: merged,
                        historyEnd: 0,
                        initialRow: initialRow,
                        predictionEnd: 0,
                        fixedEnd: 0
                    )
                )
                if self.handler.isSuccessorMode, !merged.isEmpty,
                   let markedText = self.candidateWindow.selectedText, !markedText.isEmpty {
                    self.mockClient.setMarkedText(
                        markedText,
                        selectionRange: NSRange(location: markedText.count, length: 0)
                    )
                }
            }
        }
    }

    private func applySegmentLLMScheduling() {
        let trigger = handler.segmentLLMTrigger
        guard case .start(let hiragana) = trigger else { return }
        handler.segmentLLMTrigger = .none
        segmentLLM.convert(hiragana: hiragana) { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let segState = self.handler.state.segmentState,
                  segState.segments.map(\.reading).joined() == hiragana else { return }
            self.handler.applyLLMSegmentResult(text: trimmed)
            guard let updated = self.handler.state.segmentState,
                  updated.llmWholeText != nil,
                  !updated.segments.isEmpty else { return }
            let action = self.handler.makeCandidateActionForFocusedSegment()
            if case .show(let cands, let historyEnd, let initialRow, let predictionEnd, let fixedEnd) = action {
                self.candidateWindow.apply(
                    action: .show(
                        candidates: cands,
                        historyEnd: historyEnd,
                        initialRow: initialRow,
                        predictionEnd: predictionEnd,
                        fixedEnd: fixedEnd
                    )
                )
                self.handler.applySegmentMarkedText(client: self.mockClient)
            }
        }
    }

    private func applyCandidateScorerScheduling() {
        candidateScorer.cancel()
        guard handler.lastScorerEligible else { return }
        guard !handler.pendingScorerGlobalIndices.isEmpty else { return }
        guard !candidateWindow.isExplicitlySelected else { return }
        guard !handler.state.isSegmentMode else { return }
        guard !handler.isSuccessorMode else { return }
        guard !handler.isBracketMode else { return }

        let contextForScore = llmDocumentContextPrefix()
        let reading = handler.state.composedHiragana
        let opts = handler.pendingScorerStrings
        let wasAutoShow = handler.lastCandidateListAutoShow

        let examples: [(prev: String, next: String)] =
            handler.committedHistory.last.map { lastWord in
                handler.db.fetchBigramTop(prev: lastWord, limit: 5).map { (prev: lastWord, next: $0) }
            } ?? []

        candidateScorer.score(
            candidates: opts,
            context: contextForScore,
            reading: reading,
            examples: examples
        ) { [weak self] result in
            guard let self else { return }
            guard result.confidence == .high || !wasAutoShow else { return }
            guard result.index != 0 || !wasAutoShow else { return }
            let idx = result.index
            guard idx >= 0, idx < self.handler.pendingScorerGlobalIndices.count else { return }
            guard self.candidateWindow.isVisible else { return }
            guard !self.candidateWindow.isExplicitlySelected else { return }
            guard !self.handler.state.isSegmentMode else { return }
            guard !self.handler.isSuccessorMode else { return }
            guard !self.handler.isBracketMode else { return }
            guard self.handler.state.composedHiragana == reading else { return }

            let g = self.handler.pendingScorerGlobalIndices[idx]
            self.candidateWindow.moveRow(from: g)
            self.updateMockMarkedText()
        }
    }

    private func updateMockMarkedText() {
        if let ss = handler.state.segmentState {
            let str = ss.attributedString(overrideFocusedText: candidateWindow.selectedText)
            mockClient.setMarkedText(str, selectionRange: NSRange(location: str.length, length: 0))
        } else {
            let text: String
            if candidateWindow.isVisible, let selected = candidateWindow.selectedText {
                text = selected + handler.state.pendingRomaji
            } else {
                text = handler.state.composingText
            }
            mockClient.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0))
        }
    }

    // MARK: - 実 DB スナップショット（デバッグ用）

    private func cleanupSnapshot() {
        Self.removeSnapshotArtifacts(baseURL: snapshotURL)
        snapshotURL = nil
    }

    /// `foo.db` と SQLite が隣接生成する `foo.db-wal` / `foo.db-shm` をまとめて削除する。
    private nonisolated static func removeSnapshotArtifacts(baseURL: URL?) {
        guard let base = baseURL else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: base)
        try? fm.removeItem(at: URL(fileURLWithPath: base.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: base.path + "-shm"))
    }

    private func makeRealDBSnapshot() -> DatabaseManager? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let src = appSupport.appendingPathComponent("keynaco", isDirectory: true).appendingPathComponent("history.db")
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keynaco-sandbox-\(UUID().uuidString).db")

        guard copyDatabaseToSnapshot(src: src, dst: tmp) else { return nil }

        snapshotURL = tmp
        return DatabaseManager(snapshotPath: tmp.path)
    }

    /// まず `sqlite3_backup`、失敗時はチェックポイント + 本体ファイルコピー（後者は WAL がマージできない場合にデータ欠落しうる）。
    private func copyDatabaseToSnapshot(src: URL, dst: URL) -> Bool {
        try? FileManager.default.removeItem(at: dst)
        Self.removeSnapshotArtifacts(baseURL: dst)

        if copyDatabaseUsingBackup(src: src, dst: dst) {
            return true
        }
        NSLog("[DebugSocketServer] sqlite3_backup failed; falling back to checkpoint + file copy (see checkpointAndCopyDbOnly comment)")
        try? FileManager.default.removeItem(at: dst)
        Self.removeSnapshotArtifacts(baseURL: dst)
        return checkpointAndCopyDbOnly(src: src, dst: dst)
    }

    private func copyDatabaseUsingBackup(src: URL, dst: URL) -> Bool {
        var destDb: OpaquePointer?
        guard sqlite3_open_v2(dst.path, &destDb, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let dest = destDb else { return false }
        defer { sqlite3_close(dest) }

        // バックアップ元はリーダーロックで足りる。READWRITE だと本番が WAL で掴んでいるとき BUSY になりやすい。
        var srcDb: OpaquePointer?
        guard sqlite3_open_v2(src.path, &srcDb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let source = srcDb else { return false }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 500)

        guard let backup = sqlite3_backup_init(dest, "main", source, "main") else { return false }
        defer { _ = sqlite3_backup_finish(backup) }

        while true {
            let rc = sqlite3_backup_step(backup, -1)
            if rc == SQLITE_DONE { return true }
            if rc == SQLITE_OK { continue }
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                usleep(20_000)
                continue
            }
            return false
        }
    }

    /// 案 A: メインファイルのみコピー。`PRAGMA wal_checkpoint(FULL)` が効かないと `-wal` 内の未反映フレームはコピー先に乗らない（デバッグ用途では許容）。
    private func checkpointAndCopyDbOnly(src: URL, dst: URL) -> Bool {
        try? FileManager.default.removeItem(at: dst)
        Self.removeSnapshotArtifacts(baseURL: dst)
        var tmpDb: OpaquePointer?
        if sqlite3_open_v2(src.path, &tmpDb, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = tmpDb {
            sqlite3_busy_timeout(db, 500)
            sqlite3_exec(db, "PRAGMA wal_checkpoint(FULL);", nil, nil, nil)
            sqlite3_close(db)
        }
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            return true
        } catch {
            NSLog("[DebugSocketServer] snapshot copy failed: \(error)")
            return false
        }
    }
}

// MARK: - SocketMockClient

final class SocketMockClient: TextInputClient {
    private var insertedTexts: [String] = []
    private(set) var markedText: String = ""

    func insertText(_ text: String) { insertedTexts.append(text); markedText = "" }
    func setMarkedText(_ text: String, selectionRange: NSRange) { markedText = text }
    func selectedRange() -> NSRange { NSRange(location: markedText.count, length: 0) }
    func cursorRect() -> NSRect { .zero }

    func consume() -> [String] { let r = insertedTexts; insertedTexts = []; return r }
    func reset() { insertedTexts = []; markedText = "" }
}

// MARK: - DebugCandidateWindow

struct DebugCandidateWindow {
    var isVisible = false
    var candidates: [String] = []
    var selectedRow = 0
    var historyEnd = 0
    var predictionEnd = 0
    var fixedEnd = 0
    var isExplicitlySelected = false

    var selectedText: String? {
        guard isVisible, candidates.indices.contains(selectedRow) else { return nil }
        return candidates[selectedRow]
    }

    var context: CandidateContext {
        CandidateContext(
            isVisible: isVisible,
            selectedRow: selectedRow,
            selectedText: selectedText,
            isExplicitlySelected: isExplicitlySelected,
            historyEnd: historyEnd,
            fixedEnd: fixedEnd
        )
    }

    mutating func apply(action: CandidateAction) {
        switch action {
        case .none:
            break
        case .show(let cands, let he, let initial, let pe, let fe):
            candidates = cands
            isVisible = !cands.isEmpty
            selectedRow = cands.isEmpty ? 0 : min(initial, cands.count - 1)
            historyEnd = he; predictionEnd = pe; fixedEnd = fe; isExplicitlySelected = false
        case .dismiss:
            isVisible = false; candidates = []; selectedRow = 0; isExplicitlySelected = false
        case .selectNext:
            guard isVisible, !candidates.isEmpty else { break }
            selectedRow = min(selectedRow + 1, candidates.count - 1); isExplicitlySelected = true
        case .selectPrev:
            guard isVisible, !candidates.isEmpty else { break }
            selectedRow = max(selectedRow - 1, 0); isExplicitlySelected = true
        case .deleteSelected:
            guard isVisible, candidates.indices.contains(selectedRow) else { break }
            let row = selectedRow
            candidates.remove(at: row)
            if row < predictionEnd { predictionEnd -= 1 }
            if row < historyEnd    { historyEnd -= 1 }
            if candidates.isEmpty { isVisible = false; selectedRow = 0 }
            else { selectedRow = min(selectedRow, candidates.count - 1) }
        }
    }

    /// `CandidateWindow.moveRow(from:)` と同等（候補スコアラー用）。
    mutating func moveRow(from: Int) {
        guard candidates.indices.contains(from) else { return }
        let destBefore = predictionEnd
        if from == destBefore { return }
        guard from >= predictionEnd else { return }

        let keepText = selectedText

        let fromHistoryBand = from >= predictionEnd && from < historyEnd
        let fromAzooBand = from >= historyEnd

        let item = candidates.remove(at: from)
        candidates.insert(item, at: destBefore)

        if fromHistoryBand {
            predictionEnd += 1
        } else if fromAzooBand {
            predictionEnd += 1
            historyEnd += 1
        }

        if let t = keepText, let newRow = candidates.firstIndex(of: t) {
            selectedRow = newRow
        } else {
            selectedRow = min(selectedRow, candidates.count - 1)
        }
    }
}

#endif
