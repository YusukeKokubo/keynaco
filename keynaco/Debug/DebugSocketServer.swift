#if DEBUG

import Foundation
import KeynacoCore
import Darwin
import AppKit
import SQLite3
import InputMethodKit

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
    var handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: ZenzaiSettings.makeConverter())
    let mockClient = SocketMockClient()
    var candidateWindow = DebugCandidateWindow()

    /// `set_left_context` で明示指定した左コンテキスト。nil なら committedHistory から自動計算。
    var debugLeftContextOverride: String? = nil

    /// `deinit` から参照するため `nonisolated(unsafe)`。書き込みは MainActor のみ。
    nonisolated(unsafe) var snapshotURL: URL?

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
        let dict = Self.withProtocolMetadata(processCommand(cmd))
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return #"{"error":"serialization"}"# }
        return str
    }

    // MARK: - Named key table (name → (keyCode, chars))

    static let namedKeys: [String: (UInt16, String)] = [
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

    // MARK: - Protocol metadata / error envelope

    static let protocolVersion = 1

    static let stateFieldSchemas: [String: String] = [
        "inserted": "array<string>",
        "markedText": "string",
        "composedHiragana": "string",
        "pendingRomaji": "string",
        "composingText": "string",
        "isAsciiMode": "bool",
        "isSuccessorMode": "bool",
        "isSegmentMode": "bool",
        "isBracketMode": "bool",
        "isExplicitlySelected": "bool",
        "candidateVisible": "bool",
        "selectedRow": "int",
        "selectedText": "string|null",
        "historyEnd": "int",
        "predictionEnd": "int",
        "fixedEnd": "int",
        "candidates": "array<string>",
        "committedHistory": "array<string>",
        "segmentTexts": "array<string>",
        "focusedSegmentIndex": "int",
        "isZenzaiEnabled": "bool",
        "leftSideContext": "string",
        "candidateEntries": "array<object>",
        "changed": "array<string>",
        "explain": "object",
    ]

    static func capabilities() -> [String: Any] {
        [
            "supportsSchemaCommand": true,
            "supportsSchemaExamples": true,
            "supportsNamedKeyShorthand": true,
            "supportsTypeString": true,
            "supportsSequence": true,
            "supportsTestSuite": true,
            "supportsLintSuite": true,
            "supportsWaitUntil": true,
            "supportsAssertEventually": true,
            "supportsCapture": true,
            "supportsVars": true,
            "supportsAssertions": true,
            "supportsStructuredErrors": true,
            "supportsChangedFields": true,
            "supportsCandidateEntries": true,
            "supportsExplain": true,
            "supportsGetLog": true,
            "supportsAnnotate": true,
        ]
    }

    static func buildInfo() -> [String: Any] {
        let info = Bundle.main.infoDictionary
        return [
            "commit": (info?["KeynacoBuildCommit"] as? String) ?? "unknown",
            "builtAt": (info?["KeynacoBuildTime"] as? String) ?? "unknown",
            "shortVersion": (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0",
            "build": (info?["CFBundleVersion"] as? String) ?? "0",
        ]
    }

    static func withProtocolMetadata(_ dict: [String: Any]) -> [String: Any] {
        var out = dict
        out["protocolVersion"] = protocolVersion
        out["capabilities"] = capabilities()
        out["buildInfo"] = buildInfo()
        return out
    }

    static func errorPayload(
        code: String,
        message: String,
        hint: String? = nil,
        suggestedFixes: [[String: Any]]? = nil
    ) -> [String: Any] {
        var detail: [String: Any] = [
            "code": code,
            "message": message,
        ]
        if let hint {
            detail["hint"] = hint
        }
        if let suggestedFixes, !suggestedFixes.isEmpty {
            detail["suggestedFixes"] = suggestedFixes
        }
        // 互換のため error(文字列) を残しつつ、構造化情報を errorDetail に追加する
        return [
            "error": message,
            "errorDetail": detail
        ]
    }

    // MARK: - fields / assert ヘルパー

    static func applyFields(_ dict: [String: Any], fields: [String]?) -> [String: Any] {
        guard let fields, !fields.isEmpty else { return dict }
        var keep = Set(fields)
        if dict["describe"] != nil { keep.insert("describe") }
        if dict["explain"] != nil { keep.insert("explain") }
        if dict["assertion_failed"] != nil {
            keep.insert("assertion_failed")
            keep.insert("state")
        }
        return dict.filter { keep.contains($0.key) }
    }

    static func jsonString(_ v: Any) -> String {
        // スカラー値は JSONSerialization のトップレベルとして渡せないので配列でラップして比較する
        (try? JSONSerialization.data(withJSONObject: [v])).flatMap { String(data: $0, encoding: .utf8) } ?? "\(v)"
    }

    static func isEqualJSON(_ actual: Any?, _ expected: Any) -> Bool {
        guard let actual else { return false }
        return jsonString(actual) == jsonString(expected)
    }

    static func valueCount(_ value: Any?) -> Int? {
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

    static func containsValue(_ actual: Any?, expected: Any) -> Bool {
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

    static func matchesSchema(_ value: Any?, schema rawSchema: String) -> Bool {
        let schema = rawSchema.replacingOccurrences(of: " ", with: "").lowercased()
        if schema.hasPrefix("array<"), schema.hasSuffix(">") {
            guard let array = value as? [Any] else { return false }
            let inner = String(schema.dropFirst("array<".count).dropLast())
            return array.allSatisfy { matchesSchema($0, schema: inner) }
        }
        switch schema {
        case "string":
            return value is String
        case "number", "double":
            return value is Double || value is Float || value is Int || value is NSNumber
        case "int", "integer":
            return value is Int
        case "bool", "boolean":
            return value is Bool
        case "array":
            return value is [Any]
        case "object", "dict", "dictionary":
            return value is [String: Any]
        case "null":
            return value == nil || value is NSNull
        case "any":
            return true
        default:
            return false
        }
    }

    static func applyAssert(
        _ dict: [String: Any],
        assertions: [String: Any]?,
        containsAssertions: [String: Any]?,
        notAssertions: [String: Any]?,
        schemaAssertions: [String: Any]?,
        regexAssertions: [String: Any]?
    ) -> [String: Any] {
        let hasEquality = assertions.map { !$0.isEmpty } ?? false
        let hasContains = containsAssertions.map { !$0.isEmpty } ?? false
        let hasNot = notAssertions.map { !$0.isEmpty } ?? false
        let hasSchema = schemaAssertions.map { !$0.isEmpty } ?? false
        let hasRegex = regexAssertions.map { !$0.isEmpty } ?? false
        guard hasEquality || hasContains || hasNot || hasSchema || hasRegex else { return dict }

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
        if let schemaAssertions {
            for (key, expectedSchema) in schemaAssertions {
                guard let schema = expectedSchema as? String else {
                    failures.append([
                        "kind": "schema",
                        "field": key,
                        "expected": expectedSchema,
                        "actual": "schema must be string"
                    ])
                    continue
                }
                let actual = dict[key]
                if !matchesSchema(actual, schema: schema) {
                    failures.append([
                        "kind": "schema",
                        "field": key,
                        "expected": schema,
                        "actual": actual ?? NSNull()
                    ])
                }
            }
        }
        if let regexAssertions {
            for (key, expectedRegex) in regexAssertions {
                guard let pattern = expectedRegex as? String else {
                    failures.append([
                        "kind": "regex",
                        "field": key,
                        "expected": expectedRegex,
                        "actual": "regex must be string"
                    ])
                    continue
                }
                guard let actual = dict[key] else {
                    failures.append([
                        "kind": "regex",
                        "field": key,
                        "expected": pattern,
                        "actual": NSNull()
                    ])
                    continue
                }
                let target = jsonString(actual)
                if target.range(of: pattern, options: .regularExpression) == nil {
                    failures.append([
                        "kind": "regex",
                        "field": key,
                        "expected": pattern,
                        "actual": actual
                    ])
                }
            }
        }
        if failures.isEmpty { return dict }
        var wrapped: [String: Any] = ["assertion_failed": failures, "state": dict]
        if let describe = dict["describe"] { wrapped["describe"] = describe }
        return wrapped
    }

    static func applyDescribe(_ dict: [String: Any], describe: Any?) -> [String: Any] {
        guard let describe = describe else { return dict }
        var result = dict
        result["describe"] = describe
        return result
    }

    static func valueByPath(_ root: Any, path: String) -> Any? {
        if path.isEmpty { return root }
        let parts = path.split(separator: ".").map(String.init)
        var current: Any? = root
        for part in parts {
            switch current {
            case let dict as [String: Any]:
                if let next = dict[part] {
                    current = next
                } else if let state = dict["state"] as? [String: Any], let next = state[part] {
                    // assertion_failed ラップのときは state を暗黙フォールバックとして見る
                    current = next
                } else {
                    return nil
                }
            case let array as [Any]:
                guard let idx = Int(part), array.indices.contains(idx) else { return nil }
                current = array[idx]
            default:
                return nil
            }
        }
        return current
    }

    static func resolveTemplateString(_ raw: String, vars: [String: Any]) -> Any {
        let pattern = #"\{\{([a-zA-Z0-9_.-]+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }
        let nsRaw = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nsRaw.length))
        guard !matches.isEmpty else { return raw }

        // 文字列全体が {{var}} なら、型を保ったまま置換
        if matches.count == 1, let m = matches.first, m.range.location == 0, m.range.length == nsRaw.length {
            let key = nsRaw.substring(with: m.range(at: 1))
            return valueByPath(vars, path: key) ?? raw
        }

        // 部分置換は文字列化して差し込む
        var replaced = raw
        for m in matches.reversed() {
            let key = nsRaw.substring(with: m.range(at: 1))
            let replacement = valueByPath(vars, path: key).map { jsonString($0) } ?? ""
            if let range = Range(m.range, in: replaced) {
                replaced.replaceSubrange(range, with: replacement)
            }
        }
        return replaced
    }

    static func resolveVars(in value: Any, vars: [String: Any]) -> Any {
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = resolveVars(in: v, vars: vars)
            }
            return out
        case let array as [Any]:
            return array.map { resolveVars(in: $0, vars: vars) }
        case let str as String:
            return resolveTemplateString(str, vars: vars)
        default:
            return value
        }
    }

    static func applyCapture(
        _ capture: Any?,
        from result: [String: Any],
        vars: inout [String: Any]
    ) -> [String: Any] {
        var captured: [String: Any] = [:]

        func capturePath(alias: String, path: String) {
            guard let value = valueByPath(result, path: path) else { return }
            vars[alias] = value
            captured[alias] = value
        }

        if let list = capture as? [String] {
            for path in list {
                capturePath(alias: path, path: path)
            }
        } else if let map = capture as? [String: Any] {
            for (alias, rawPath) in map {
                if let path = rawPath as? String {
                    capturePath(alias: alias, path: path)
                }
            }
        }
        return captured
    }

    static func finalize(_ dict: [String: Any], cmd: [String: Any]) -> [String: Any] {
        let withDescribe = applyDescribe(dict, describe: cmd["describe"])
        let withExplain = applyExplainIfRequested(withDescribe, cmd: cmd)
        let fields = cmd["fields"] as? [String]
        let assertions = cmd["assert"] as? [String: Any]
        let containsAssertions = cmd["assert_contains"] as? [String: Any]
        let notAssertions = cmd["assert_not"] as? [String: Any]
        let schemaAssertions = cmd["assert_schema"] as? [String: Any]
        let regexAssertions = cmd["assert_regex"] as? [String: Any]
        return applyAssert(
            applyFields(withExplain, fields: fields),
            assertions: assertions,
            containsAssertions: containsAssertions,
            notAssertions: notAssertions,
            schemaAssertions: schemaAssertions,
            regexAssertions: regexAssertions
        )
    }

    static func applyExplainIfRequested(_ dict: [String: Any], cmd: [String: Any]) -> [String: Any] {
        guard (cmd["explain"] as? Bool) == true else { return dict }

        // 状態辞書を返すレスポンスにだけ explain を付与する
        guard dict["composingText"] != nil else { return dict }
        var out = dict

        let modeFlags: [(String, String)] = [
            ("isAsciiMode", "ascii"),
            ("isSuccessorMode", "successor"),
            ("isSegmentMode", "segment"),
            ("isBracketMode", "bracket"),
        ]
        let activeModes = modeFlags.compactMap { key, label in
            (dict[key] as? Bool) == true ? label : nil
        }

        let candidateVisible = dict["candidateVisible"] as? Bool ?? false
        let selectedRow = dict["selectedRow"] as? Int ?? 0
        let selectedText = dict["selectedText"] as? String
        let candidates = dict["candidates"] as? [String] ?? []
        let candidateEntries = dict["candidateEntries"] as? [[String: Any]] ?? []
        var sectionCounts: [String: Int] = [:]
        for entry in candidateEntries {
            if let section = entry["section"] as? String {
                sectionCounts[section, default: 0] += 1
            }
        }

        out["explain"] = [
            "activeModes": activeModes,
            "composition": [
                "composingText": dict["composingText"] ?? "",
                "composedHiragana": dict["composedHiragana"] ?? "",
                "pendingRomaji": dict["pendingRomaji"] ?? "",
            ],
            "candidateSummary": [
                "visible": candidateVisible,
                "count": candidates.count,
                "selectedRow": selectedRow,
                "selectedText": selectedText as Any,
                "sectionCounts": sectionCounts,
            ],
            "changedFields": dict["changed"] as? [String] ?? []
        ]
        return out
    }

    static func waitConditionMatched(state: [String: Any], field: String, wait: [String: Any]) -> Bool {
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

    func waitUntil(_ wait: [String: Any], cmd: [String: Any]) -> [String: Any] {
        guard let field = wait["field"] as? String else {
            return Self.finalize(
                Self.errorPayload(
                    code: "WAIT_UNTIL_MISSING_FIELD",
                    message: "wait_until requires field",
                    hint: #"Use {"wait_until":{"field":"candidates","minCount":1}}."#,
                    suggestedFixes: [
                        ["schema": true],
                        ["wait_until": ["field": "candidates", "minCount": 1, "timeoutMs": 1500]]
                    ]
                ),
                cmd: cmd
            )
        }
        let hasCondition = wait["equals"] != nil || wait["contains"] != nil || wait["minCount"] != nil
        guard hasCondition else {
            return Self.finalize(
                Self.errorPayload(
                    code: "WAIT_UNTIL_MISSING_CONDITION",
                    message: "wait_until requires one of equals, contains, minCount",
                    hint: "Set at least one of equals/contains/minCount.",
                    suggestedFixes: [
                        ["wait_until": ["field": field, "equals": true]],
                        ["wait_until": ["field": field, "contains": "漢字"]],
                        ["wait_until": ["field": field, "minCount": 1]]
                    ]
                ),
                cmd: cmd
            )
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

    func assertEventually(_ wait: [String: Any], cmd: [String: Any]) -> [String: Any] {
        let field = wait["field"] as? String ?? "unknown"
        let raw = waitUntil(wait, cmd: [:])
        if (raw["matched"] as? Bool) == true {
            return Self.finalize([
                "ok": true,
                "matched": true,
                "waitField": field,
                "state": raw["state"] as? [String: Any] ?? [:]
            ], cmd: cmd)
        }

        let expected: Any = {
            if let equals = wait["equals"] { return ["equals": equals] }
            if let contains = wait["contains"] { return ["contains": contains] }
            if let minCount = wait["minCount"] { return ["minCount": minCount] }
            return "equals|contains|minCount"
        }()
        let state = raw["state"] as? [String: Any] ?? [:]
        let actual = state[field] ?? NSNull()
        return Self.finalize([
            "ok": false,
            "matched": false,
            "timedOut": true,
            "waitField": field,
            "assertion_failed": [[
                "kind": "eventually",
                "field": field,
                "expected": expected,
                "actual": actual
            ]],
            "state": state
        ], cmd: cmd)
    }

    static func compactFailureLine(_ failure: [String: Any]) -> String {
        let phase = failure["phase"] as? String ?? "unknown"
        if phase == "step" {
            let stepIndex = failure["stepIndex"] as? Int ?? -1
            let stepPhase = failure["stepPhase"] as? String ?? "cmd"
            let field = failure["field"] as? String ?? "?"
            let kind = failure["kind"] as? String ?? "assert"
            let expected = failure["expected"].map { jsonString($0) } ?? "null"
            return "step#\(stepIndex) [\(stepPhase)] \(kind) \(field) expected \(expected)"
        }
        if phase == "final" {
            let field = failure["field"] as? String ?? "?"
            let kind = failure["kind"] as? String ?? "assert"
            let expected = failure["expected"].map { jsonString($0) } ?? "null"
            return "final \(kind) \(field) expected \(expected)"
        }
        if phase == "suite" {
            return failure["message"] as? String ?? "suite expectation failed"
        }
        return failure["message"] as? String ?? "assertion failed"
    }

    static let knownAssertionFields: Set<String> = [
        "inserted", "markedText", "composedHiragana", "pendingRomaji", "composingText",
        "isAsciiMode", "isSuccessorMode", "isSegmentMode", "isBracketMode",
        "isExplicitlySelected", "candidateVisible", "selectedRow", "selectedText",
        "historyEnd", "predictionEnd", "fixedEnd", "candidates", "committedHistory",
        "segmentTexts", "focusedSegmentIndex",
        "candidateEntries", "changed", "explain",
        "ok", "matched", "timedOut", "waitField", "state", "steps", "last",
    ]

    static let knownCommandKeys: Set<String> = [
        "reset", "state", "get_log", "annotate",
        "wait_until", "assert_eventually", "seed_noun_bigram", "seed_history",
        "set_last_noun", "set_surrounding", "set_left_context",
        "test_suite", "sequence", "type_string", "key", "keyCode", "lint_suite",
        "capture", "vars", "schema", "with_examples", "explain",
    ]

    static func schemaExamples() -> [[String: Any]] {
        [
            [
                "name": "schema_with_examples",
                "command": [
                    "schema": true,
                    "with_examples": true
                ]
            ],
            [
                "name": "type_string_and_convert",
                "command": [
                    "type_string": "kanzi",
                    "then": "space",
                    "fields": ["candidates", "historyEnd"]
                ]
            ],
            [
                "name": "sequence_with_capture",
                "command": [
                    "sequence": [
                        ["type_string": "kanzi", "then": "space", "capture": ["picked": "selectedText"]],
                        ["key": "enter", "assert_contains": ["inserted": "{{picked}}"]]
                    ],
                    "vars": [:]
                ]
            ],
            [
                "name": "minimal_test_suite",
                "command": [
                    "test_suite": [
                        [
                            "name": "kanzi変換",
                            "cmds": [
                                ["type_string": "kanzi"],
                                ["key": "space", "assert": ["candidateVisible": true]]
                            ],
                            "assert_contains": ["candidates": "漢字"]
                        ]
                    ]
                ]
            ]
        ]
    }

    static func schemaResponse(cmd: [String: Any]) -> [String: Any] {
        var root: [String: Any] = [
            "schema": [
                "commandTriggers": Array(knownCommandKeys).sorted(),
                "assertionFields": Array(knownAssertionFields).sorted(),
                "namedKeys": Array(namedKeys.keys).sorted(),
                "stateFields": stateFieldSchemas,
                "structuredError": [
                    "error": "string",
                    "errorDetail": [
                        "code": "string",
                        "message": "string",
                        "hint": "string(optional)",
                        "suggestedFixes": "array<object>(optional)",
                    ]
                ],
            ]
        ]
        if (cmd["with_examples"] as? Bool) == true,
           var schema = root["schema"] as? [String: Any] {
            schema["examples"] = schemaExamples()
            root["schema"] = schema
        }
        return finalize(root, cmd: cmd)
    }

    static func lintAssertionKeys(
        _ cmd: [String: Any],
        location: String
    ) -> [[String: Any]] {
        var issues: [[String: Any]] = []
        for key in ["assert", "assert_contains", "assert_not", "assert_schema", "assert_regex"] {
            guard let fields = cmd[key] as? [String: Any] else { continue }
            for field in fields.keys where !knownAssertionFields.contains(field) {
                issues.append([
                    "severity": "warning",
                    "location": location,
                    "message": "Unknown assertion field '\(field)' in \(key)"
                ])
            }
        }
        return issues
    }

    static func lintSuite(
        suite: [[String: Any]],
        beforeEach: [[String: Any]],
        afterEach: [[String: Any]],
        cmd: [String: Any]
    ) -> [String: Any] {
        var issues: [[String: Any]] = []
        var scenarioCount = 0

        func lintCommand(_ command: [String: Any], location: String) {
            let hasKnownCommand = command.keys.contains { knownCommandKeys.contains($0) }
            if !hasKnownCommand {
                issues.append([
                    "severity": "error",
                    "location": location,
                    "message": "Command has no executable key"
                ])
            }
            if let wait = command["wait_until"] as? [String: Any] {
                if wait["field"] as? String == nil {
                    issues.append([
                        "severity": "error",
                        "location": location,
                        "message": "wait_until requires field"
                    ])
                }
                let hasCondition = wait["equals"] != nil || wait["contains"] != nil || wait["minCount"] != nil
                if !hasCondition {
                    issues.append([
                        "severity": "error",
                        "location": location,
                        "message": "wait_until requires equals/contains/minCount"
                    ])
                }
            }
            if let wait = command["assert_eventually"] as? [String: Any] {
                if wait["field"] as? String == nil {
                    issues.append([
                        "severity": "error",
                        "location": location,
                        "message": "assert_eventually requires field"
                    ])
                }
                let hasCondition = wait["equals"] != nil || wait["contains"] != nil || wait["minCount"] != nil
                if !hasCondition {
                    issues.append([
                        "severity": "error",
                        "location": location,
                        "message": "assert_eventually requires equals/contains/minCount"
                    ])
                }
            }
            if let capture = command["capture"] {
                let validCapture = (capture as? [String]) != nil || (capture as? [String: Any]) != nil
                if !validCapture {
                    issues.append([
                        "severity": "error",
                        "location": location,
                        "message": "capture must be array<string> or object<string,string>"
                    ])
                }
            }
            if let regexAssertions = command["assert_regex"] as? [String: Any] {
                for (field, rawPattern) in regexAssertions {
                    guard let pattern = rawPattern as? String else {
                        issues.append([
                            "severity": "error",
                            "location": location,
                            "message": "assert_regex.\(field) must be string"
                        ])
                        continue
                    }
                    if (try? NSRegularExpression(pattern: pattern)) == nil {
                        issues.append([
                            "severity": "error",
                            "location": location,
                            "message": "assert_regex.\(field) has invalid regex pattern"
                        ])
                    }
                }
            }
            issues.append(contentsOf: lintAssertionKeys(command, location: location))
        }

        for (i, command) in beforeEach.enumerated() {
            lintCommand(command, location: "before_each[\(i)]")
        }
        for (i, command) in afterEach.enumerated() {
            lintCommand(command, location: "after_each[\(i)]")
        }

        for (idx, scenario) in suite.enumerated() {
            scenarioCount += 1
            let location = "test_suite[\(idx)]"
            let scenarioCmds = scenario["cmds"] as? [[String: Any]]
            if scenarioCmds == nil {
                issues.append([
                    "severity": "error",
                    "location": location,
                    "message": "cmds must be an array"
                ])
                continue
            }
            if scenarioCmds?.isEmpty == true {
                issues.append([
                    "severity": "warning",
                    "location": location,
                    "message": "cmds is empty"
                ])
            }
            let expectsTimeout = scenario["expect_timeout"] as? Bool ?? false
            let hasWaitUntil = (scenarioCmds ?? []).contains {
                $0["wait_until"] != nil || $0["assert_eventually"] != nil
            }
            if expectsTimeout && !hasWaitUntil {
                issues.append([
                    "severity": "warning",
                    "location": location,
                    "message": "expect_timeout=true but no wait_until/assert_eventually command found"
                ])
            }
            for (i, command) in (scenario["before_each"] as? [[String: Any]] ?? []).enumerated() {
                lintCommand(command, location: "\(location).before_each[\(i)]")
            }
            for (i, command) in (scenarioCmds ?? []).enumerated() {
                lintCommand(command, location: "\(location).cmds[\(i)]")
            }
            for (i, command) in (scenario["after_each"] as? [[String: Any]] ?? []).enumerated() {
                lintCommand(command, location: "\(location).after_each[\(i)]")
            }
            issues.append(contentsOf: lintAssertionKeys(scenario, location: location))
        }

        let errorCount = issues.filter { ($0["severity"] as? String) == "error" }.count
        let warningCount = issues.filter { ($0["severity"] as? String) == "warning" }.count
        return finalize([
            "ok": errorCount == 0,
            "issues": issues,
            "summary": [
                "scenarios": scenarioCount,
                "errors": errorCount,
                "warnings": warningCount
            ]
        ], cmd: cmd)
    }

    // MARK: - コマンド処理（MainActor 上で実行）

    func processCommand(_ cmd: [String: Any]) -> [String: Any] {
        if cmd["schema"] != nil {
            return Self.schemaResponse(cmd: cmd)
        }

        if cmd["reset"] != nil { return handleReset(cmd: cmd) }
        if cmd["state"] != nil { return handleState(cmd: cmd) }
        if cmd["get_log"] != nil { return handleGetLog(cmd: cmd) }
        if cmd["annotate"] is String { return handleAnnotate(cmd: cmd) }
        if cmd["lint_suite"] is [[String: Any]] { return handleLintSuite(cmd: cmd) }
        if cmd["wait_until"] is [String: Any] { return handleWaitUntil(cmd: cmd) }
        if cmd["assert_eventually"] is [String: Any] { return handleAssertEventually(cmd: cmd) }
        if cmd["seed_noun_bigram"] is [String: Any] { return handleSeedNounBigram(cmd: cmd) }
        if cmd["seed_history"] is [String: Any] { return handleSeedHistory(cmd: cmd) }
        if cmd["set_last_noun"] is String { return handleSetLastNoun(cmd: cmd) }
        if cmd["set_surrounding"] is [String: Any] { return handleSetSurrounding(cmd: cmd) }
        if cmd["set_left_context"] is String { return handleSetLeftContext(cmd: cmd) }
        if cmd["test_suite"] is [[String: Any]] { return handleTestSuite(cmd: cmd) }
        if cmd["sequence"] is [[String: Any]] { return handleSequence(cmd: cmd) }
        if cmd["type_string"] is String { return handleTypeString(cmd: cmd) }
        if cmd["key"] is String { return handleKey(cmd: cmd) }
        return handleKeyEvent(cmd: cmd)
    }

    func makeResponse(inserted: [String]) -> [String: Any] {
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
            "virtualHistoryPrefix": snap.virtualHistoryPrefix,
            "segmentTexts":       snap.segmentTexts,
            "focusedSegmentIndex": snap.focusedSegmentIndex,
            "isZenzaiEnabled":    handler.azooKeyConverter.isZenzaiEnabled,
            "leftSideContext":    handler.leftSideContext,
            "surroundingAfter":   mockClient.documentAfter,
            "candidateEntries":   Self.makeCandidateEntries(
                candidates: snap.candidates,
                fixedEnd: snap.fixedEnd,
                predictionEnd: candidateWindow.predictionEnd,
                historyEnd: snap.historyEnd
            ),
        ]
        if let st = snap.selectedText { dict["selectedText"] = st }
        return dict
    }

    static func candidateSection(
        row: Int,
        fixedEnd: Int,
        predictionEnd: Int,
        historyEnd: Int
    ) -> String {
        if row < fixedEnd {
            return "fixed"
        }
        if row < predictionEnd {
            return "prediction"
        }
        if row < historyEnd {
            return "history"
        }
        return "dictionary_or_special"
    }

    static func makeCandidateEntries(
        candidates: [String],
        fixedEnd: Int,
        predictionEnd: Int,
        historyEnd: Int
    ) -> [[String: Any]] {
        candidates.enumerated().map { idx, text in
            [
                "index": idx,
                "text": text,
                "section": candidateSection(
                    row: idx,
                    fixedEnd: fixedEnd,
                    predictionEnd: predictionEnd,
                    historyEnd: historyEnd
                )
            ]
        }
    }

    static let changedFieldTargets: [String] = [
        "inserted", "markedText", "composedHiragana", "pendingRomaji", "composingText",
        "isAsciiMode", "isSuccessorMode", "isSegmentMode", "isBracketMode",
        "isExplicitlySelected", "candidateVisible", "selectedRow", "selectedText",
        "historyEnd", "predictionEnd", "fixedEnd", "candidates", "committedHistory",
        "segmentTexts", "focusedSegmentIndex",
        "candidateEntries"
    ]

    static func computeChangedFields(
        before: [String: Any],
        after: [String: Any]
    ) -> [String] {
        changedFieldTargets.filter { key in
            jsonString(before[key] ?? NSNull()) != jsonString(after[key] ?? NSNull())
        }
    }

    func debugLeftContextPrefix() -> String {
        if let override = debugLeftContextOverride { return override }
        return handler.committedHistory.suffix(5).joined()
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
}

#endif
