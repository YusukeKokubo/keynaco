#if DEBUG

import Foundation
import KeynacoCore
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
    private var handler = InputHandler(db: DatabaseManager(inMemory: true, seedPresets: true), azooKeyConverter: ZenzaiSettings.makeConverter())
    private let mockClient = SocketMockClient()
    private var candidateWindow = DebugCandidateWindow()

    private let successorLLM = LLMSuccessorFetcher()
    private let segmentLLM = LLMSegmentConverter()

    /// `reset` のたびに増やし、直前のキー処理で飛ばした LLM 完了コールバックを無効化する。
    private var llmEpoch: UInt64 = 0

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

    // MARK: - Named key table (name → (keyCode, chars))

    private static let namedKeys: [String: (UInt16, String)] = [
        "space":     (49,  " "),
        "enter":     (36,  "\r"),
        "backspace": (51,  "\u{08}"),
        "escape":    (53,  ""),
        "tab":       (48,  "\t"),
        "down":      (125, ""),
        "up":        (126, ""),
        "left":      (123, ""),
        "right":     (124, ""),
        "f6":        (97,  ""),
        "f7":        (98,  ""),
        "f8":        (100, ""),
        "f9":        (101, ""),
        "f10":       (109, ""),
        "eisu":      (102, ""),
        "kana":      (104, ""),
    ]

    // MARK: - fields / assert ヘルパー

    private static func applyFields(_ dict: [String: Any], fields: [String]?) -> [String: Any] {
        guard let fields, !fields.isEmpty else { return dict }
        var keep = Set(fields)
        if dict["describe"] != nil { keep.insert("describe") }
        if dict["assertion_failed"] != nil {
            keep.insert("assertion_failed")
            keep.insert("state")
        }
        return dict.filter { keep.contains($0.key) }
    }

    private static func jsonString(_ v: Any) -> String {
        // スカラー値は JSONSerialization のトップレベルとして渡せないので配列でラップして比較する
        (try? JSONSerialization.data(withJSONObject: [v])).flatMap { String(data: $0, encoding: .utf8) } ?? "\(v)"
    }

    private static func isEqualJSON(_ actual: Any?, _ expected: Any) -> Bool {
        guard let actual else { return false }
        return jsonString(actual) == jsonString(expected)
    }

    private static func valueCount(_ value: Any?) -> Int? {
        switch value {
        case let arr as [Any]:
            return arr.count
        case let dict as [String: Any]:
            return dict.count
        case let str as String:
            return str.count
        default:
            return nil
        }
    }

    private static func containsValue(_ actual: Any?, expected: Any) -> Bool {
        guard let actual else { return false }
        if let actualString = actual as? String, let expectedString = expected as? String {
            return actualString.contains(expectedString)
        }
        if let actualArray = actual as? [Any] {
            if let expectedArray = expected as? [Any] {
                return expectedArray.allSatisfy { ev in
                    actualArray.contains { av in jsonString(av) == jsonString(ev) }
                }
            }
            return actualArray.contains { av in jsonString(av) == jsonString(expected) }
        }
        if let actualDict = actual as? [String: Any], let expectedDict = expected as? [String: Any] {
            return expectedDict.allSatisfy { key, value in
                actualDict[key].map { jsonString($0) == jsonString(value) } ?? false
            }
        }
        if let actualDict = actual as? [String: Any], let expectedKey = expected as? String {
            return actualDict[expectedKey] != nil
        }
        return false
    }

    private static func applyAssert(
        _ dict: [String: Any],
        assertions: [String: Any]?,
        containsAssertions: [String: Any]?,
        notAssertions: [String: Any]?
    ) -> [String: Any] {
        let hasEquality = assertions.map { !$0.isEmpty } ?? false
        let hasContains = containsAssertions.map { !$0.isEmpty } ?? false
        let hasNot = notAssertions.map { !$0.isEmpty } ?? false
        guard hasEquality || hasContains || hasNot else { return dict }

        var failures: [[String: Any]] = []
        if let assertions {
            for (key, expected) in assertions {
                let actual = dict[key]
                if !isEqualJSON(actual, expected) {
                    failures.append([
                        "kind": "equals",
                        "field": key,
                        "expected": expected,
                        "actual": actual ?? NSNull()
                    ])
                }
            }
        }
        if let containsAssertions {
            for (key, expected) in containsAssertions {
                let actual = dict[key]
                if !containsValue(actual, expected: expected) {
                    failures.append([
                        "kind": "contains",
                        "field": key,
                        "expected": expected,
                        "actual": actual ?? NSNull()
                    ])
                }
            }
        }
        if let notAssertions {
            for (key, expected) in notAssertions {
                let actual = dict[key]
                if isEqualJSON(actual, expected) {
                    failures.append([
                        "kind": "not_equals",
                        "field": key,
                        "expected": expected,
                        "actual": actual ?? NSNull()
                    ])
                }
            }
        }
        if failures.isEmpty { return dict }
        var wrapped: [String: Any] = ["assertion_failed": failures, "state": dict]
        if let describe = dict["describe"] { wrapped["describe"] = describe }
        return wrapped
    }

    private static func applyDescribe(_ dict: [String: Any], describe: Any?) -> [String: Any] {
        guard let describe = describe else { return dict }
        var result = dict
        result["describe"] = describe
        return result
    }

    private static func finalize(_ dict: [String: Any], cmd: [String: Any]) -> [String: Any] {
        let withDescribe = applyDescribe(dict, describe: cmd["describe"])
        let fields = cmd["fields"] as? [String]
        let assertions = cmd["assert"] as? [String: Any]
        let containsAssertions = cmd["assert_contains"] as? [String: Any]
        let notAssertions = cmd["assert_not"] as? [String: Any]
        return applyAssert(
            applyFields(withDescribe, fields: fields),
            assertions: assertions,
            containsAssertions: containsAssertions,
            notAssertions: notAssertions
        )
    }

    private static func waitConditionMatched(state: [String: Any], field: String, wait: [String: Any]) -> Bool {
        guard let actual = state[field] else { return false }
        if let equals = wait["equals"] {
            return isEqualJSON(actual, equals)
        }
        if let contains = wait["contains"] {
            return containsValue(actual, expected: contains)
        }
        if let minCount = wait["minCount"] as? Int {
            return (valueCount(actual) ?? 0) >= minCount
        }
        return false
    }

    private func waitUntil(_ wait: [String: Any], cmd: [String: Any]) -> [String: Any] {
        guard let field = wait["field"] as? String else {
            return Self.finalize(["error": "wait_until requires field"], cmd: cmd)
        }
        let hasCondition = wait["equals"] != nil || wait["contains"] != nil || wait["minCount"] != nil
        guard hasCondition else {
            return Self.finalize(["error": "wait_until requires one of equals, contains, minCount"], cmd: cmd)
        }
        let timeoutMs = max(0, wait["timeoutMs"] as? Int ?? 1000)
        let intervalMs = max(1, wait["intervalMs"] as? Int ?? 50)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)

        var state = makeResponse(inserted: [])
        while true {
            if Self.waitConditionMatched(state: state, field: field, wait: wait) {
                return Self.finalize([
                    "ok": true,
                    "matched": true,
                    "waitField": field,
                    "state": state
                ], cmd: cmd)
            }
            if Date() >= deadline { break }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(Double(intervalMs) / 1000.0))
            state = makeResponse(inserted: [])
        }

        return Self.finalize([
            "ok": false,
            "matched": false,
            "timedOut": true,
            "waitField": field,
            "state": state
        ], cmd: cmd)
    }

    // MARK: - コマンド処理（MainActor 上で実行）

    private func processCommand(_ cmd: [String: Any]) -> [String: Any] {
        if cmd["reset"] != nil {
            cleanupSnapshot()
            successorLLM.cancel()
            segmentLLM.cancel()
            llmEpoch &+= 1
            let useRealDB = cmd["useRealDB"] as? Bool ?? false
            let converter = ZenzaiSettings.makeConverter()
            if useRealDB, let db = makeRealDBSnapshot() {
                handler = InputHandler(db: db, azooKeyConverter: converter)
            } else {
                handler = InputHandler(db: DatabaseManager(inMemory: true, seedPresets: true), azooKeyConverter: converter)
            }
            InputHandler.isAsciiMode = false
            candidateWindow = DebugCandidateWindow()
            mockClient.reset()
            return Self.finalize(["ok": true], cmd: cmd)
        }

        if cmd["state"] != nil {
            return Self.finalize(makeResponse(inserted: []), cmd: cmd)
        }

        // {"wait_until": {"field":"successorLLMSurfaceExtras","minCount":1,"timeoutMs":1500}}
        if let wait = cmd["wait_until"] as? [String: Any] {
            return waitUntil(wait, cmd: cmd)
        }

        // {"seed_bigram": {"prev": "今日", "input": "は", "output": "は", "count": 10}}
        if let seed = cmd["seed_bigram"] as? [String: Any] {
            guard let prev   = seed["prev"]   as? String,
                  let input  = seed["input"]  as? String,
                  let output = seed["output"] as? String else {
                return Self.finalize(["error": "seed_bigram requires prev, input, output"], cmd: cmd)
            }
            let count = seed["count"] as? Int ?? 1
            handler.db.debugSeedBigram(prev: prev, input: input, output: output, count: count)
            return Self.finalize(["ok": true], cmd: cmd)
        }

        // {"seed_history": {"input": "かんじ", "output": "漢字"}}
        if let seed = cmd["seed_history"] as? [String: Any] {
            guard let input  = seed["input"]  as? String,
                  let output = seed["output"] as? String else {
                return Self.finalize(["error": "seed_history requires input and output"], cmd: cmd)
            }
            let times = seed["times"] as? Int ?? 1
            for _ in 0..<times { handler.db.debugSeedHistory(input: input, output: output) }
            return Self.finalize(["ok": true], cmd: cmd)
        }

        // {"test_suite": [{"name":"...", "cmds":[...], "assert": {...}}, ...]}
        if let suite = cmd["test_suite"] as? [[String: Any]] {
            let defaultUseRealDB = cmd["useRealDB"] as? Bool ?? false
            let globalBeforeEach = cmd["before_each"] as? [[String: Any]] ?? []
            let globalAfterEach = cmd["after_each"] as? [[String: Any]] ?? []
            let failFast = cmd["fail_fast"] as? Bool ?? false
            var scenarios: [[String: Any]] = []
            var passCount = 0
            let suiteStart = Date()

            for (idx, scenario) in suite.enumerated() {
                let scenarioStart = Date()
                let name = scenario["name"] as? String ?? "scenario_\(idx + 1)"
                let useRealDB = scenario["useRealDB"] as? Bool ?? defaultUseRealDB
                _ = processCommand(["reset": true, "useRealDB": useRealDB])

                guard let cmds = scenario["cmds"] as? [[String: Any]] else {
                    scenarios.append([
                        "name": name,
                        "ok": false,
                        "error": "cmds must be an array of command objects"
                    ])
                    continue
                }

                let scenarioBeforeEach = scenario["before_each"] as? [[String: Any]] ?? []
                let scenarioAfterEach = scenario["after_each"] as? [[String: Any]] ?? []
                var combined: [[String: Any]] = []
                var stepPhases: [(phase: String, index: Int)] = []
                for (i, c) in globalBeforeEach.enumerated() {
                    combined.append(c)
                    stepPhases.append(("before_each", i))
                }
                for (i, c) in scenarioBeforeEach.enumerated() {
                    combined.append(c)
                    stepPhases.append(("before_each", globalBeforeEach.count + i))
                }
                for (i, c) in cmds.enumerated() {
                    combined.append(c)
                    stepPhases.append(("cmd", i))
                }
                for (i, c) in scenarioAfterEach.enumerated() {
                    combined.append(c)
                    stepPhases.append(("after_each", i))
                }
                for (i, c) in globalAfterEach.enumerated() {
                    combined.append(c)
                    stepPhases.append(("after_each", scenarioAfterEach.count + i))
                }

                var seqCmd: [String: Any] = ["sequence": combined]
                if let fields = scenario["fields"] as? [String] { seqCmd["fields"] = fields }
                let seqResult = processCommand(seqCmd)
                let steps = seqResult["steps"] as? [[String: Any]] ?? []
                let failedSteps = steps.filter { $0["assertion_failed"] != nil }.count
                let last = seqResult["last"] as? [String: Any] ?? [:]
                let finalCheck = Self.applyAssert(
                    last,
                    assertions: scenario["assert"] as? [String: Any],
                    containsAssertions: scenario["assert_contains"] as? [String: Any],
                    notAssertions: scenario["assert_not"] as? [String: Any]
                )
                let hasFinalFailure = finalCheck["assertion_failed"] != nil
                let ok = failedSteps == 0 && !hasFinalFailure && seqResult["error"] == nil
                if ok { passCount += 1 }

                var failureDetails: [[String: Any]] = []
                for (stepIndex, step) in steps.enumerated() {
                    guard let failures = step["assertion_failed"] as? [[String: Any]] else { continue }
                    for failure in failures {
                        var detail = failure
                        detail["phase"] = "step"
                        detail["stepIndex"] = stepIndex
                        if stepPhases.indices.contains(stepIndex) {
                            detail["stepPhase"] = stepPhases[stepIndex].phase
                            detail["stepInPhaseIndex"] = stepPhases[stepIndex].index
                        }
                        if let stepDescribe = step["describe"] {
                            detail["stepDescribe"] = stepDescribe
                        }
                        failureDetails.append(detail)
                    }
                }
                if let finalFailures = finalCheck["assertion_failed"] as? [[String: Any]] {
                    for failure in finalFailures {
                        var detail = failure
                        detail["phase"] = "final"
                        failureDetails.append(detail)
                    }
                }

                var result: [String: Any] = [
                    "name": name,
                    "ok": ok,
                    "stepCount": steps.count,
                    "failedStepCount": failedSteps,
                    "failedAssertions": failureDetails,
                    "durationMs": Int(Date().timeIntervalSince(scenarioStart) * 1000),
                    "last": finalCheck
                ]
                if scenario["describe"] != nil {
                    result = Self.applyDescribe(result, describe: scenario["describe"])
                }
                if scenario["return_steps"] as? Bool == true {
                    result["steps"] = steps
                }
                if let err = seqResult["error"] { result["error"] = err }
                scenarios.append(result)
                if failFast && !ok { break }
            }

            let summary: [String: Any] = [
                "total": scenarios.count,
                "passed": passCount,
                "failed": max(0, scenarios.count - passCount),
                "durationMs": Int(Date().timeIntervalSince(suiteStart) * 1000),
                "stoppedEarly": failFast && scenarios.count < suite.count
            ]
            return Self.finalize(["results": scenarios, "summary": summary], cmd: cmd)
        }

        // {"sequence": [{cmd}, {cmd}, ...]} — バッチ処理。各ステップの状態を配列で返す
        if let seq = cmd["sequence"] as? [[String: Any]] {
            let fields     = cmd["fields"]     as? [String]
            let assertions = cmd["assert"]     as? [String: Any]
            let containsAssertions = cmd["assert_contains"] as? [String: Any]
            let notAssertions = cmd["assert_not"] as? [String: Any]
            var steps: [[String: Any]] = []
            for step in seq {
                steps.append(processCommand(step))
            }
            let last = steps.last ?? [:]
            let filteredSteps = steps.map { Self.applyFields($0, fields: fields) }
            let filteredLast  = Self.applyAssert(
                Self.applyFields(last, fields: fields),
                assertions: assertions,
                containsAssertions: containsAssertions,
                notAssertions: notAssertions
            )
            return Self.applyDescribe(["steps": filteredSteps, "last": filteredLast], describe: cmd["describe"])
        }

        // {"type_string": "kanzi"} — 文字列を1文字ずつ送信。最終状態を返す（return_steps: true で全ステップも付加）
        if let text = cmd["type_string"] as? String {
            let fields     = cmd["fields"]     as? [String]
            let assertions = cmd["assert"]     as? [String: Any]
            let containsAssertions = cmd["assert_contains"] as? [String: Any]
            let notAssertions = cmd["assert_not"] as? [String: Any]
            var steps: [[String: Any]] = []
            for ch in text {
                let s = String(ch)
                steps.append(processCommand(["keyCode": 0, "chars": s, "base": s, "mods": 0]))
            }
            if let thenKey = cmd["then"] as? String {
                steps.append(processCommand(["key": thenKey, "mods": cmd["mods"] ?? 0]))
            }
            var result = Self.applyAssert(
                Self.applyFields(steps.last ?? [:], fields: fields),
                assertions: assertions,
                containsAssertions: containsAssertions,
                notAssertions: notAssertions
            )
            if cmd["return_steps"] as? Bool == true {
                result["steps"] = steps.map { Self.applyFields($0, fields: fields) }
            }
            return Self.applyDescribe(result, describe: cmd["describe"])
        }

        // {"key": "space"} ショートハンド — namedKeys テーブルから keyCode/chars を解決
        if let keyName = cmd["key"] as? String {
            guard let (resolvedKeyCode, resolvedChars) = Self.namedKeys[keyName] else {
                return Self.finalize(["error": "unknown key name: \(keyName)"], cmd: cmd)
            }
            let mods = NSEvent.ModifierFlags(rawValue: (cmd["mods"] as? UInt) ?? 0)
            var expanded = cmd
            expanded.removeValue(forKey: "key")
            expanded["keyCode"] = Int(resolvedKeyCode)
            expanded["chars"]   = resolvedChars
            expanded["base"]    = resolvedChars
            expanded["mods"]    = mods.rawValue
            return processCommand(expanded)
        }

        let keyCode: UInt16
        switch cmd["keyCode"] {
        case let kc as UInt16: keyCode = kc
        case let kc as Int:    keyCode = UInt16(kc)
        default: return Self.finalize(["error": "missing keyCode"], cmd: cmd)
        }

        let chars = cmd["chars"] as? String
        let base  = cmd["base"]  as? String ?? chars
        let mods  = NSEvent.ModifierFlags(rawValue: (cmd["mods"] as? UInt) ?? 0)

        handler.leftSideContext = llmDocumentContextPrefix()
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

        let result = makeResponse(inserted: mockClient.consume())
        return Self.finalize(result, cmd: cmd)
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
    }

    private func applySuccessorLLMScheduling() {
        let trigger = handler.successorLLMTrigger
        guard trigger != .none else { return }
        handler.successorLLMTrigger = .none
        let schedulingEpoch = llmEpoch

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
                guard schedulingEpoch == self.llmEpoch else { return }
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
                guard schedulingEpoch == self.llmEpoch else { return }
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
        let schedulingEpoch = llmEpoch
        segmentLLM.convert(hiragana: hiragana) { [weak self] text in
            guard let self else { return }
            guard schedulingEpoch == self.llmEpoch else { return }
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
}

#endif
