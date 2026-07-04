#if DEBUG

import Foundation
import KeynacoCore
import AppKit
import InputMethodKit

extension DebugSocketServer {
    func handleReset(cmd: [String: Any]) -> [String: Any] {
    cleanupSnapshot()
    cancelAzooKeyAsyncWork()
    handler.azooKeyConverter.latencyStats.reset()
    let useRealDB = cmd["useRealDB"] as? Bool ?? false
    let converter = ZenzaiSettings.makeConverter()
    if useRealDB {
        handler = InputHandler(db: DatabaseManager.shared, azooKeyConverter: converter)
    } else {
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: converter)
    }
    handler.deferAzooKeyWhileTyping = true
    handler.isAsciiMode = false
    handler.candidateSession.reset()
    mockClient.reset()
    debugLeftContextOverride = nil
    IMESandboxWindow.shared.clearSandbox()
    return Self.finalize(["ok": true], cmd: cmd)
    }

    func handleState(cmd: [String: Any]) -> [String: Any] {
    var state = makeResponse(inserted: [])
    state["changed"] = []
    return Self.finalize(state, cmd: cmd)
    }

    func handleGetLog(cmd: [String: Any]) -> [String: Any] {
    let lineFilter = cmd["line"] as? Int
    let entries = IMESandboxWindow.shared.exportLog(line: lineFilter)
    return Self.finalize(["log": entries, "count": entries.count], cmd: cmd)
    }

    func handleAnnotate(cmd: [String: Any]) -> [String: Any] {
    let text = cmd["annotate"] as! String
    IMESandboxWindow.shared.appendAnnotation(text)
    return Self.finalize(["ok": true], cmd: cmd)
    }

    func handleLintSuite(cmd: [String: Any]) -> [String: Any] {
    let suite = cmd["lint_suite"] as! [[String: Any]]
    let beforeEach = cmd["before_each"] as? [[String: Any]] ?? []
    let afterEach = cmd["after_each"] as? [[String: Any]] ?? []
    return Self.lintSuite(suite: suite, beforeEach: beforeEach, afterEach: afterEach, cmd: cmd)
    }

    func handleWaitUntil(cmd: [String: Any]) -> [String: Any] {
    let wait = cmd["wait_until"] as! [String: Any]
    return waitUntil(wait, cmd: cmd)
    }

    func handleAssertEventually(cmd: [String: Any]) -> [String: Any] {
    let wait = cmd["assert_eventually"] as! [String: Any]
    return assertEventually(wait, cmd: cmd)
    }

    func handleSeedHistory(cmd: [String: Any]) -> [String: Any] {
    let seed = cmd["seed_history"] as! [String: Any]
    guard let input  = seed["input"]  as? String,
          let output = seed["output"] as? String else {
        return Self.finalize(
            Self.errorPayload(
                code: "SEED_HISTORY_MISSING_FIELDS",
                message: "seed_history requires input and output",
                hint: #"Use {"seed_history":{"input":"かんじ","output":"漢字"}}."#,
                suggestedFixes: [
                    ["seed_history": ["input": "かんじ", "output": "漢字", "times": 3]]
                ]
            ),
            cmd: cmd
        )
    }
    let times = seed["times"] as? Int ?? 1
    for _ in 0..<times { handler.db.debugSeedHistory(input: input, output: output) }
    return Self.finalize(["ok": true], cmd: cmd)
    }

    /// `set_surrounding` / `set_left_context` 後に `leftSideContext` を再計算して返す共通ペイロード。
    func finalizeLeftContextCommand(cmd: [String: Any], extra: [String: Any] = [:]) -> [String: Any] {
        syncLeftSideContext()
        var payload: [String: Any] = ["ok": true, "leftSideContext": handler.leftContext.combined]
        payload["sessionTextBuffer"] = handler.sessionTextBuffer
        for (k, v) in extra { payload[k] = v }
        return Self.finalize(payload, cmd: cmd)
    }

    func handleSetSurrounding(cmd: [String: Any]) -> [String: Any] {
    let sur = cmd["set_surrounding"] as! [String: Any]
    if let b = sur["before"] as? String { mockClient.documentBefore = b }
    if let a = sur["after"] as? String { mockClient.documentAfter = a }
    return finalizeLeftContextCommand(cmd: cmd)
    }

    func handleSetLeftContext(cmd: [String: Any]) -> [String: Any] {
    let ctx = cmd["set_left_context"] as! String
    debugLeftContextOverride = ctx.isEmpty ? nil : ctx
    return finalizeLeftContextCommand(cmd: cmd)
    }

    func handleTestSuite(cmd: [String: Any]) async -> [String: Any] {
    let suite = cmd["test_suite"] as! [[String: Any]]
    let defaultUseRealDB = cmd["useRealDB"] as? Bool ?? false
    let globalVars = cmd["vars"] as? [String: Any] ?? [:]
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
        _ = await processCommandAsync(["reset": true, "useRealDB": useRealDB])

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
        var scenarioVars = globalVars
        if let localVars = scenario["vars"] as? [String: Any] {
            for (k, v) in localVars { scenarioVars[k] = v }
        }
        if !scenarioVars.isEmpty { seqCmd["vars"] = scenarioVars }
        let seqResult = await processCommandAsync(seqCmd)
        let steps = seqResult["steps"] as? [[String: Any]] ?? []
        let failedSteps = steps.filter { $0["assertion_failed"] != nil }.count
        let last = seqResult["last"] as? [String: Any] ?? [:]
        let expectError = scenario["expect_error"] as? Bool ?? false
        let expectTimeout = scenario["expect_timeout"] as? Bool ?? false
        let stepErrors: [[String: Any]] = steps.enumerated().compactMap { index, step in
            guard let err = step["error"] else { return nil }
            return [
                "phase": "step",
                "stepIndex": index,
                "stepPhase": stepPhases.indices.contains(index) ? stepPhases[index].phase : "cmd",
                "kind": "error",
                "field": "error",
                "expected": expectError ? "error" : "none",
                "actual": err,
                "message": "step returned error: \(err)"
            ]
        }
        let stepTimeouts: [[String: Any]] = steps.enumerated().compactMap { index, step in
            guard (step["timedOut"] as? Bool) == true else { return nil }
            return [
                "phase": "step",
                "stepIndex": index,
                "stepPhase": stepPhases.indices.contains(index) ? stepPhases[index].phase : "cmd",
                "kind": "timeout",
                "field": "timedOut",
                "expected": expectTimeout,
                "actual": true,
                "message": "step timed out"
            ]
        }
        let finalCheck = Self.applyAssert(
            last,
            assertions: scenario["assert"] as? [String: Any],
            containsAssertions: scenario["assert_contains"] as? [String: Any],
            notAssertions: scenario["assert_not"] as? [String: Any],
            schemaAssertions: scenario["assert_schema"] as? [String: Any],
            regexAssertions: scenario["assert_regex"] as? [String: Any]
        )
        let hasError = !stepErrors.isEmpty || seqResult["error"] != nil || finalCheck["error"] != nil
        let hasTimeout = !stepTimeouts.isEmpty || (finalCheck["timedOut"] as? Bool ?? false)
        var suiteExpectationFailures: [[String: Any]] = []
        if expectError && !hasError {
            suiteExpectationFailures.append([
                "phase": "suite",
                "kind": "expected_error",
                "message": "expect_error=true but no error occurred"
            ])
        }
        if !expectError && hasError {
            suiteExpectationFailures.append([
                "phase": "suite",
                "kind": "unexpected_error",
                "message": "unexpected error occurred"
            ])
        }
        if expectTimeout && !hasTimeout {
            suiteExpectationFailures.append([
                "phase": "suite",
                "kind": "expected_timeout",
                "message": "expect_timeout=true but no timeout occurred"
            ])
        }
        if !expectTimeout && hasTimeout {
            suiteExpectationFailures.append([
                "phase": "suite",
                "kind": "unexpected_timeout",
                "message": "unexpected timeout occurred"
            ])
        }
        let hasFinalFailure = finalCheck["assertion_failed"] != nil
        let ok = failedSteps == 0 &&
                 !hasFinalFailure &&
                 suiteExpectationFailures.isEmpty &&
                 (expectError || !hasError) &&
                 (expectTimeout || !hasTimeout)
        if ok { passCount += 1 }

        var failureDetails: [[String: Any]] = []
        failureDetails.append(contentsOf: stepErrors)
        failureDetails.append(contentsOf: stepTimeouts)
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
        failureDetails.append(contentsOf: suiteExpectationFailures)
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
            "compactFailures": failureDetails.map(Self.compactFailureLine),
            "hasError": hasError,
            "hasTimeout": hasTimeout,
            "durationMs": Int(Date().timeIntervalSince(scenarioStart) * 1000),
            "last": finalCheck
        ]
        if scenario["describe"] != nil {
            result = Self.applyDescribe(result, describe: scenario["describe"])
        }
        if scenario["return_steps"] as? Bool == true {
            result["steps"] = steps
        }
        if scenario["return_vars"] as? Bool == true, let seqVars = seqResult["vars"] {
            result["vars"] = seqVars
        }
        if let err = seqResult["error"] { result["error"] = err }
        if !ok {
            var repro: [String: Any] = [
                "test_suite": [scenario]
            ]
            if useRealDB {
                repro["useRealDB"] = true
            }
            if !globalBeforeEach.isEmpty {
                repro["before_each"] = globalBeforeEach
            }
            if !globalAfterEach.isEmpty {
                repro["after_each"] = globalAfterEach
            }
            if !globalVars.isEmpty {
                repro["vars"] = globalVars
            }
            result["reproCommand"] = repro
        }
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

    func handleSequence(cmd: [String: Any]) async -> [String: Any] {
    let seq = cmd["sequence"] as! [[String: Any]]
    let fields     = cmd["fields"]     as? [String]
    let assertions = cmd["assert"]     as? [String: Any]
    let containsAssertions = cmd["assert_contains"] as? [String: Any]
    let notAssertions = cmd["assert_not"] as? [String: Any]
    var vars = cmd["vars"] as? [String: Any] ?? [:]
    var steps: [[String: Any]] = []
    for rawStep in seq {
        let resolvedAny = Self.resolveVars(in: rawStep, vars: vars)
        guard var resolvedStep = resolvedAny as? [String: Any] else {
            steps.append(Self.errorPayload(
                code: "INVALID_STEP_COMMAND",
                message: "invalid step command",
                hint: "Each sequence step must be an object.",
                suggestedFixes: [
                    ["sequence": [["key": "space"]]],
                    ["schema": true]
                ]
            ))
            continue
        }
        let captureSpec = resolvedStep["capture"]
        resolvedStep.removeValue(forKey: "capture")
        var result = await processCommandAsync(resolvedStep)
        let captured = Self.applyCapture(captureSpec, from: result, vars: &vars)
        if !captured.isEmpty {
            result["captured"] = captured
        }
        steps.append(result)
    }
    let last = steps.last ?? [:]
    let filteredSteps = steps.map { Self.applyFields($0, fields: fields) }
    var filteredLast  = Self.applyAssert(
        Self.applyFields(last, fields: fields),
        assertions: assertions,
        containsAssertions: containsAssertions,
        notAssertions: notAssertions,
        schemaAssertions: cmd["assert_schema"] as? [String: Any],
        regexAssertions: cmd["assert_regex"] as? [String: Any]
    )
    filteredLast = Self.applyExplainIfRequested(filteredLast, cmd: cmd)
    return Self.applyDescribe(["steps": filteredSteps, "last": filteredLast, "vars": vars], describe: cmd["describe"])
    }

    func handleTypeString(cmd: [String: Any]) async -> [String: Any] {
    let text = cmd["type_string"] as! String
    let fields     = cmd["fields"]     as? [String]
    let assertions = cmd["assert"]     as? [String: Any]
    let containsAssertions = cmd["assert_contains"] as? [String: Any]
    let notAssertions = cmd["assert_not"] as? [String: Any]
    var steps: [[String: Any]] = []
    for ch in text {
        let s = String(ch)
        steps.append(await processCommandAsync(["keyCode": 0, "chars": s, "base": s, "mods": 0]))
    }
    if let thenKey = cmd["then"] as? String {
        steps.append(await processCommandAsync(["key": thenKey, "mods": cmd["mods"] ?? 0]))
    }
    var result = Self.applyAssert(
        Self.applyFields(steps.last ?? [:], fields: fields),
        assertions: assertions,
        containsAssertions: containsAssertions,
        notAssertions: notAssertions,
        schemaAssertions: cmd["assert_schema"] as? [String: Any],
        regexAssertions: cmd["assert_regex"] as? [String: Any]
    )
    result = Self.applyExplainIfRequested(result, cmd: cmd)
    if cmd["return_steps"] as? Bool == true {
        result["steps"] = steps.map { Self.applyFields($0, fields: fields) }
    }
    return Self.applyDescribe(result, describe: cmd["describe"])
    }

    func handleKey(cmd: [String: Any]) async -> [String: Any] {
    let keyName = cmd["key"] as! String
    guard let (resolvedKeyCode, resolvedChars) = Self.namedKeys[keyName] else {
        return Self.finalize(
            Self.errorPayload(
                code: "UNKNOWN_KEY_NAME",
                message: "unknown key name: \(keyName)",
                hint: "Call {\"schema\": true} to inspect supported named keys.",
                suggestedFixes: [
                    ["schema": true],
                    ["key": "space"],
                    ["key": "enter"]
                ]
            ),
            cmd: cmd
        )
    }
    let mods = NSEvent.ModifierFlags(rawValue: (cmd["mods"] as? UInt) ?? 0)
    var expanded = cmd
    expanded.removeValue(forKey: "key")
    expanded["keyCode"] = Int(resolvedKeyCode)
    expanded["chars"]   = resolvedChars
    expanded["base"]    = resolvedChars
    expanded["mods"]    = mods.rawValue
    return await processCommandAsync(expanded)
    }

    func handleKeyEvent(cmd: [String: Any]) -> [String: Any] {
    let keyCode: UInt16
    switch cmd["keyCode"] {
    case let kc as UInt16: keyCode = kc
    case let kc as Int:    keyCode = UInt16(kc)
    default:
    return Self.finalize(
        Self.errorPayload(
            code: "MISSING_KEYCODE",
            message: "missing keyCode",
            hint: "Use keyCode/chars/base/mods or the shorthand {\"key\":\"space\"}.",
            suggestedFixes: [
                ["key": "space"],
                ["keyCode": 49, "chars": " ", "base": " ", "mods": 0],
                ["schema": true]
            ]
        ),
        cmd: cmd
    )
    }

    let chars = cmd["chars"] as? String
    let base  = cmd["base"]  as? String ?? chars
    let mods  = NSEvent.ModifierFlags(rawValue: (cmd["mods"] as? UInt) ?? 0)

    let composingTextWasEmpty = !handler.state.isComposing
    let composedHiraganaWasEmpty = handler.state.composedHiragana.isEmpty
    let pendingRomajiWasEmpty = handler.state.pendingRomaji.isEmpty
    let backspacePenalizeOutput: String? = (
        keyCode == KeyCode.backspace
        && composingTextWasEmpty
        && composedHiraganaWasEmpty
        && pendingRomajiWasEmpty
    ) ? handler.lastConfirmedContext?.output : nil
    syncLeftSideContext()
    warmRichCacheBeforeExplicitIfNeeded(keyCode: keyCode)
    let generation = azooKeyScheduler.onKeyDown()
    let before = makeResponse(inserted: [])
    let pre = KeyEventPipeline.preSnapshot(handler: handler)
    let keyResult = KeyEventPipeline.runHandle(
        handler: &handler,
        keyCode: keyCode,
        characters: chars,
        baseCharacters: base,
        modifiers: mods,
        pre: pre,
        client: mockClient
    )
    if keyCode == KeyCode.backspace, !keyResult.consumed {
        if let output = backspacePenalizeOutput {
            mockClient.removeDocumentSuffix(output)
        } else {
            mockClient.removeLastDocumentCharacter()
        }
    }
    handler.applyPostKeyDownCandidateAndIMK(
        action: keyResult.candidateAction,
        client: mockClient
    )
    scheduleSandboxAzooKeyIfNeeded(generation: generation, consumed: keyResult.consumed)
    let insertedTexts = mockClient.consume()
    for text in insertedTexts {
        let reading = handler.lastConfirmedContext?.input ?? handler.lastCommittedReading ?? ""
        schedulePOSClassification(output: text, reading: reading)
    }

    var result = makeResponse(inserted: insertedTexts)
    result["changed"] = Self.computeChangedFields(before: before, after: result)
    IMESandboxWindow.shared.appendSocketSnapshot(result, inserted: insertedTexts)
    if keyCode == 36 {
    let stillComposing = !handler.state.composedHiragana.isEmpty
        || handler.state.isComposing
        || !handler.state.pendingRomaji.isEmpty
    if !stillComposing {
        IMESandboxWindow.shared.finishCurrentLine()
    }
    }
    return Self.finalize(result, cmd: cmd)
    }

    /// `{"query_pos": ["東京", "確認して", ...]}` → `{"results": [{"output":"東京","pos":"proper_noun/place"}, ...]}`
    func handleQueryPos(cmd: [String: Any]) -> [String: Any] {
        guard let outputs = cmd["query_pos"] as? [String] else {
            return ["error": "query_pos must be an array of strings"]
        }
        let entries = handler.db.fetchAllHistory()
        let map = Dictionary(grouping: entries, by: \.output)
        let results: [[String: Any]] = outputs.map { output in
            if let entry = map[output]?.first {
                var row: [String: Any] = ["output": output, "pos": entry.pos ?? "(nil)"]
                if let lcid = entry.lcid { row["lcid"] = lcid }
                return row
            }
            return ["output": output, "pos": "(not in db)"]
        }
        return Self.finalize(["results": results], cmd: cmd)
    }

    func handlePosAvailability(cmd: [String: Any]) -> [String: Any] {
        Self.finalize(["availability": "available", "engine": "AzooKey"], cmd: cmd)
    }

    func handleStats(cmd: [String: Any]) -> [String: Any] {
        let snap = handler.azooKeyConverter.latencyStats.snapshot()
        return Self.finalize(["stats": snap.asDictionary()], cmd: cmd)
    }

    /// `{"diagnostics": true}` で直近 `assembleCandidateList` の入力・`initialText`・`scoredSources` 等を返す。
    func handleDiagnostics(cmd: [String: Any]) -> [String: Any] {
        if let diag = handler.lastCandidateBuildDiagnostics {
            return Self.finalize(["diagnostics": diag.asDictionary()], cmd: cmd)
        }
        return Self.finalize(["diagnostics": NSNull()], cmd: cmd)
    }

    /// `{"set_latency_label": "before-debounce-change"}` / `{"set_latency_label": null}`
    func handleSetLatencyLabel(cmd: [String: Any]) -> [String: Any] {
        let raw = cmd["set_latency_label"]
        if raw is NSNull {
            handler.azooKeyConverter.latencyStats.currentLabel = nil
            return Self.finalize(["ok": true, "label": NSNull()], cmd: cmd)
        }
        guard let label = raw as? String else {
            return Self.finalize(["error": "set_latency_label must be a string or null"], cmd: cmd)
        }
        handler.azooKeyConverter.latencyStats.currentLabel = label
        return Self.finalize(["ok": true, "label": label], cmd: cmd)
    }

    /// `{"read_latency_log": true}` → 直近 20 行の JSONL を返す。
    func handleReadLatencyLog(cmd: [String: Any]) -> [String: Any] {
        let fileURL = DatabaseManager.latencyLogURL
        let lines = TypingLatencyStats.readRecentLines(from: fileURL)
        return Self.finalize([
            "lines": lines,
            "path": fileURL.path,
            "count": lines.count,
        ], cmd: cmd)
    }

    /// `{"pos_backfill": true}` → 未分類 history を全件再分類。
    /// `{"pos_backfill": {"limit": 100}}` → 最大 100 output まで。
    func handlePosBackfill(cmd: [String: Any]) -> [String: Any] {
        let payload = cmd["pos_backfill"]
        let limit = (payload as? [String: Any])?["limit"] as? Int
        let remainingBefore = handler.db.countUnclassifiedHistoryOutputs()
        var result: POSBackfillResult!
        DispatchQueue.global(qos: .utility).sync {
            result = AzooKeyPOSBackfill.run(db: handler.db, converter: posLookupConverter, limit: limit)
        }
        let remainingAfter = handler.db.countUnclassifiedHistoryOutputs()
        return Self.finalize([
            "classified": result.classified,
            "skipped": result.skipped,
            "total": result.total,
            "remainingBefore": remainingBefore,
            "remainingAfter": remainingAfter,
        ], cmd: cmd)
    }

    // MARK: - benchmark

    /// `{"benchmark": {"sequence": "kanzi", "repeat": 200, "leftContext": ""}}` →
    /// `handler.handle()` を直接計時して p50/p95/p99/max/mean を返す。
    ///
    /// - `sequence`: 打鍵する文字列（デフォルト `"kanzi"`）
    /// - `repeat`: 繰り返し回数（デフォルト 200）
    /// - `leftContext`: AzooKey / Zenzai に渡す左文脈（デフォルト空 = 文脈なし）
    /// - `includeAzooKey`: `"space"` — 各イテレーションで type → `wait_azoo_key` → Space `handle()` のみ計測
    func handleBenchmark(cmd: [String: Any]) -> [String: Any] {
        let config = cmd["benchmark"] as! [String: Any]
        if config["includeAzooKey"] as? String == "space" {
            return ["error": "includeAzooKey=space requires async benchmark; use processCommandAsync"]
        }
        return finalizeBenchmark(
            cmd: cmd,
            config: config,
            durations: runSyncKeyBenchmark(config: config)
        )
    }

    func handleBenchmarkAsync(cmd: [String: Any]) async -> [String: Any] {
        let config = cmd["benchmark"] as! [String: Any]
        let includeAzooKey = config["includeAzooKey"] as? String
        let durations: [Double]
        if includeAzooKey == "space" || includeAzooKey == "space_immediate" {
            durations = await runSpaceKeyBenchmark(
                config: config,
                waitForPrefetch: includeAzooKey == "space"
            )
        } else {
            durations = runSyncKeyBenchmark(config: config)
        }
        return finalizeBenchmark(cmd: cmd, config: config, durations: durations)
    }

    private func configureBenchmarkConverter(leftContextStr: String) {
        let converter = ZenzaiSettings.makeConverter()
        handler.azooKeyConverter = converter
        handler.leftContext = leftContextStr.isEmpty
            ? .empty
            : LeftContext(sessionBuffer: "", imkBefore: nil, combined: leftContextStr)
    }

    private func resetBenchmarkIteration() {
        handler.state = CompositionState()
        handler.candidateSession.reset()
        _ = mockClient.consume()
        mockClient.reset()
        handler.isAsciiMode = false
    }

    private func benchmarkSimulateKey(
        keyCode: UInt16 = 0,
        characters: String,
        baseCharacters: String? = nil
    ) {
        let base = baseCharacters ?? characters
        syncLeftSideContext()
        let generation = azooKeyScheduler.onKeyDown()
        let pre = KeyEventPipeline.preSnapshot(handler: handler)
        let keyResult = KeyEventPipeline.runHandle(
            handler: &handler,
            keyCode: keyCode,
            characters: characters,
            baseCharacters: base,
            modifiers: [],
            pre: pre,
            client: mockClient
        )
        handler.applyPostKeyDownCandidateAndIMK(
            action: keyResult.candidateAction,
            client: mockClient
        )
        scheduleSandboxAzooKeyIfNeeded(generation: generation, consumed: keyResult.consumed)
        _ = mockClient.consume()
    }

    private func runSyncKeyBenchmark(config: [String: Any]) -> [Double] {
        let sequence = config["sequence"] as? String ?? "kanzi"
        let repeatCount = config["repeat"] as? Int ?? 200
        let leftContextStr = config["leftContext"] as? String ?? ""

        configureBenchmarkConverter(leftContextStr: leftContextStr)

        var durations: [Double] = []
        durations.reserveCapacity(sequence.count * repeatCount)

        for _ in 0..<repeatCount {
            resetBenchmarkIteration()
            for ch in sequence {
                let s = String(ch)
                let t0 = CFAbsoluteTimeGetCurrent()
                benchmarkSimulateKey(characters: s)
                let dtMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                durations.append(dtMs)
            }
        }
        return durations
    }

    private func runSpaceKeyBenchmark(
        config: [String: Any],
        waitForPrefetch: Bool
    ) async -> [Double] {
        let sequence = config["sequence"] as? String ?? "kanzi"
        let repeatCount = config["repeat"] as? Int ?? 50
        let leftContextStr = config["leftContext"] as? String ?? ""

        configureBenchmarkConverter(leftContextStr: leftContextStr)

        var durations: [Double] = []
        durations.reserveCapacity(repeatCount)

        for _ in 0..<repeatCount {
            resetBenchmarkIteration()
            for ch in sequence {
                benchmarkSimulateKey(characters: String(ch))
            }
            if waitForPrefetch {
                _ = await azooKeyScheduler.waitUntilIdle()
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            benchmarkSimulateKey(keyCode: KeyCode.space, characters: " ", baseCharacters: " ")
            let dtMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            durations.append(dtMs)
        }
        return durations
    }

    private func finalizeBenchmark(
        cmd: [String: Any],
        config: [String: Any],
        durations: [Double]
    ) -> [String: Any] {
        let sequence = config["sequence"] as? String ?? "kanzi"
        let repeatCount = config["repeat"] as? Int ?? 200
        let leftContextStr = config["leftContext"] as? String ?? ""
        let includeAzooKey = config["includeAzooKey"] as? String

        let sorted = durations.sorted()
        let count = sorted.count
        guard count > 0 else {
            return Self.finalize(Self.errorPayload(code: "BENCHMARK_EMPTY", message: "no durations"), cmd: cmd)
        }

        func pct(_ p: Int) -> Double {
            let idx = min(count - 1, count * p / 100)
            return round(sorted[idx] * 10) / 10
        }
        let mean = round(sorted.reduce(0, +) / Double(count) * 10) / 10

        var benchmark: [String: Any] = [
            "sequence": sequence,
            "repeat": repeatCount,
            "totalKeys": count,
            "zenzaiEnabled": handler.azooKeyConverter.isZenzaiEnabled,
            "leftContext": leftContextStr,
            "meanMs": mean,
            "p50Ms": pct(50),
            "p95Ms": pct(95),
            "p99Ms": pct(99),
            "maxMs": pct(100),
            "exceeds16ms": pct(95) > 16.0,
        ]
        if let includeAzooKey { benchmark["includeAzooKey"] = includeAzooKey }
        return Self.finalize(["benchmark": benchmark], cmd: cmd)
    }

    /// InputController.schedulePOSClassification と同経路で POS 分類を行う。
    func schedulePOSClassification(output: String, reading: String) {
        guard HiraganaPreferredBuiltins.words[output] == nil else { return }
        guard let c = AzooKeyPOSClassifier.classify(
            output: output, reading: reading, converter: posLookupConverter
        ) else { return }
        handler.db.updatePOSClassification(output: output, pos: c.pos, lcid: c.lcid)
    }

}

#endif
