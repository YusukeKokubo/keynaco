#if DEBUG

import Foundation
import Darwin
import AppKit

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
    private var handler = InputHandler(db: DatabaseManager(inMemory: true))
    private let mockClient = SocketMockClient()
    private var candidateWindow = DebugCandidateWindow()

    private init() {}

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
            handler = InputHandler(db: DatabaseManager(inMemory: true))
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
            "fixedEnd":           snap.fixedEnd,
            "candidates":         snap.candidates,
            "committedHistory":   snap.committedHistory,
            "segmentTexts":       snap.segmentTexts,
            "focusedSegmentIndex": snap.focusedSegmentIndex,
        ]
        if let st = snap.selectedText { dict["selectedText"] = st }
        return dict
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
        case .show(let cands, let he, let initial, _, let fe):
            candidates = cands
            isVisible = !cands.isEmpty
            selectedRow = cands.isEmpty ? 0 : min(initial, cands.count - 1)
            historyEnd = he; fixedEnd = fe; isExplicitlySelected = false
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
            candidates.remove(at: selectedRow)
            if candidates.isEmpty { isVisible = false; selectedRow = 0 }
            else { selectedRow = min(selectedRow, candidates.count - 1) }
        }
    }
}

#endif
