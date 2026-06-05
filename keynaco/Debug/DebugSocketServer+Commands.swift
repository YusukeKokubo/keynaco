#if DEBUG

import Foundation
import KeynacoCore
import AppKit
import InputMethodKit

extension DebugSocketServer {
    func handleReset(cmd: [String: Any]) -> [String: Any] {
    cleanupSnapshot()
    let useRealDB = cmd["useRealDB"] as? Bool ?? false
    let converter = ZenzaiSettings.makeConverter()
    if useRealDB {
        handler = InputHandler(db: DatabaseManager.shared, azooKeyConverter: converter)
    } else {
        handler = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: converter)
    }
    InputHandler.isAsciiMode = false
    candidateWindow = DebugCandidateWindow()
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

    func handleSetSurrounding(cmd: [String: Any]) -> [String: Any] {
    let sur = cmd["set_surrounding"] as! [String: Any]
    if let b = sur["before"] as? String { mockClient.documentBefore = b }
    if let a = sur["after"] as? String { mockClient.documentAfter = a }
    return Self.finalize(["ok": true], cmd: cmd)
    }

    func handleSetLeftContext(cmd: [String: Any]) -> [String: Any] {
    let ctx = cmd["set_left_context"] as! String
    debugLeftContextOverride = ctx.isEmpty ? nil : ctx
    return Self.finalize(["ok": true], cmd: cmd)
    }

    func handleTestSuite(cmd: [String: Any]) -> [String: Any] {
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
        var scenarioVars = globalVars
        if let localVars = scenario["vars"] as? [String: Any] {
            for (k, v) in localVars { scenarioVars[k] = v }
        }
        if !scenarioVars.isEmpty { seqCmd["vars"] = scenarioVars }
        let seqResult = processCommand(seqCmd)
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

    func handleSequence(cmd: [String: Any]) -> [String: Any] {
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
        var result = processCommand(resolvedStep)
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

    func handleTypeString(cmd: [String: Any]) -> [String: Any] {
    let text = cmd["type_string"] as! String
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

    func handleKey(cmd: [String: Any]) -> [String: Any] {
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
    return processCommand(expanded)
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

    let composingTextWasEmpty = handler.state.composingText.isEmpty
    let composedHiraganaWasEmpty = handler.state.composedHiragana.isEmpty
    let pendingRomajiWasEmpty = handler.state.pendingRomaji.isEmpty
    let backspacePenalizeOutput: String? = (
        keyCode == KeyCode.backspace
        && composingTextWasEmpty
        && composedHiraganaWasEmpty
        && pendingRomajiWasEmpty
    ) ? handler.lastConfirmedContext?.output : nil
    handler.leftSideContext = debugLeftContextPrefix()
    let before = makeResponse(inserted: [])
    let (consumed, action) = handler.handle(
    keyCode: keyCode,
    characters: chars,
    baseCharacters: base,
    modifiers: mods,
    candidate: candidateWindow.context,
    client: mockClient
    )
    if keyCode == KeyCode.backspace, !consumed {
        if let output = backspacePenalizeOutput {
            mockClient.removeDocumentSuffix(output)
        } else {
            mockClient.removeLastDocumentCharacter()
        }
    }
    applyCandidateAction(action)
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
        || !handler.state.composingText.isEmpty
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
                return ["output": output, "pos": entry.pos ?? "(nil)"]
            }
            return ["output": output, "pos": "(not in db)"]
        }
        return Self.finalize(["results": results], cmd: cmd)
    }

    func handlePosAvailability(cmd: [String: Any]) -> [String: Any] {
        Self.finalize(["availability": "available", "engine": "AzooKey"], cmd: cmd)
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

    /// InputController.schedulePOSClassification と同経路で POS 分類を行う。
    func schedulePOSClassification(output: String, reading: String) {
        guard HiraganaPreferredBuiltins.words[output] == nil else { return }
        guard let c = AzooKeyPOSClassifier.classify(
            output: output, reading: reading, converter: posLookupConverter
        ) else { return }
        handler.db.updatePOS(output: output, pos: c.pos)
    }

    /// `InputController.applyPostKeyDownEffects` の候補ウィンドウ副作用を模倣する。
    func applyCandidateAction(_ action: CandidateAction) {
        candidateWindow.apply(action: action)
        switch action {
        case .show:
            if MarkedTextSync.needsCandidateOnly(
                isBracketMode: handler.isBracketMode,
                candidateVisible: candidateWindow.isVisible,
                composedHiragana: handler.state.composedHiragana
            ) {
                syncMarkedTextForDebug()
            }
        case .selectNext, .selectPrev:
            syncMarkedTextForDebug()
        default:
            break
        }
    }

    func syncMarkedTextForDebug() {
        let text = MarkedTextSync.resolve(
            isBracketMode: handler.isBracketMode,
            candidateVisible: candidateWindow.isVisible,
            composedHiragana: handler.state.composedHiragana,
            pendingRomaji: handler.state.pendingRomaji,
            composingText: handler.state.composingText,
            selectedCandidate: candidateWindow.selectedText
        )
        mockClient.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0))
    }
}

#endif
