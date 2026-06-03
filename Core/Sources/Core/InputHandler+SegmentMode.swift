import AppKit

// MARK: - 文節選択モード（AzooKey Desktop `.selecting` 準拠）
//
// Space で `.selecting` 相当に入る。`firstClauseResults` + `mainResults` をマージした候補から
// 左端文節を選び、Enter で `composingCount`（inputLength）分だけ部分確定 → 残りで再変換。
// Shift+←/→ で変換範囲を 1 文字調整（`didExperienceSegmentEdition` → main のみ）。

public extension InputHandler {

    mutating func enterSegmentMode() -> CandidateAction {
        state.absorbPendingIntoComposed()
        let fullReading = state.composedHiragana

        if fullReading.allSatisfy({ $0.isASCII }) {
            return buildCandidateList()
        }
        guard !fullReading.isEmpty else { return .dismiss }

        let raw = azooKeyConverter.requestConversionResult(
            hiragana: fullReading,
            leftSideContext: azooKeyLeftContext,
            richCandidates: true
        )
        let engineRows = AzooKeyCandidateMerge.mergedList(
            result: raw,
            convertTarget: fullReading,
            segmentEdition: false
        )
        guard !engineRows.isEmpty else {
            return buildCandidateList()
        }

        state.segmentState = SegmentState(
            convertTarget: fullReading,
            rows: engineRows,
            selectedIndex: 0
        )
        state.composedHiragana = fullReading
        return refreshClauseCandidateAction()
    }

    private mutating func refreshClauseCandidateAction() -> CandidateAction {
        guard var ss = state.segmentState else { return .dismiss }
        let reading = ss.clauseReading
        let engineTexts = ss.rows.map(\.text)
        let action = buildCandidateList(
            forReading: reading,
            azooKeyEngineTexts: engineTexts,
            autoShow: false
        )
        if case .show(let candidates, let historyEnd, let initialRow, _, let fixedEnd) = action {
            ss.displayHistoryEnd = historyEnd
            ss.selectedIndex = min(initialRow, max(0, candidates.count - 1))
            ss.rows = syncRowsWithDisplayCandidates(
                displayCandidates: candidates,
                previousRows: ss.rows,
                clauseReading: reading
            )
            state.segmentState = ss
            return .show(
                candidates: candidates,
                historyEnd: historyEnd,
                initialRow: ss.selectedIndex,
                predictionEnd: historyEnd,
                fixedEnd: fixedEnd
            )
        }
        state.segmentState = ss
        return action
    }

    /// 表示リストとエンジン行の `inputLength` を対応付ける（履歴行は文節読み全体長）。
    private func syncRowsWithDisplayCandidates(
        displayCandidates: [String],
        previousRows: [AzooKeyClauseCandidate],
        clauseReading: String
    ) -> [AzooKeyClauseCandidate] {
        var engineByText: [String: AzooKeyClauseCandidate] = [:]
        for row in previousRows {
            engineByText[row.text] = row
        }
        let clauseLen = max(1, clauseReading.count)
        return displayCandidates.map { text in
            if let engine = engineByText[text] {
                return engine
            }
            return AzooKeyClauseCandidate(text: text, inputLength: clauseLen)
        }
    }

    mutating func makeCandidateActionForFocusedSegment() -> CandidateAction {
        refreshClauseCandidateAction()
    }

    mutating func handleSegmentModeKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        guard state.segmentState != nil else { return (false, .none) }

        switch keyCode {
        case KeyCode.leftArrow:
            if modifiers.contains(.shift) {
                return resizeClauseEnd(delta: -1, candidate: candidate, client: client)
            }
            return (true, .none)

        case KeyCode.rightArrow:
            if modifiers.contains(.shift) {
                return resizeClauseEnd(delta: 1, candidate: candidate, client: client)
            }
            if modifiers.intersection([.command, .control, .option]).isEmpty {
                return (true, confirmCurrentSegmentAndAdvance(candidate: candidate, client: client))
            }
            return (true, .none)

        case KeyCode.space, KeyCode.tab, KeyCode.downArrow:
            return (true, .selectNext)

        case KeyCode.upArrow:
            return (true, .selectPrev)

        case KeyCode.enter:
            return (true, confirmCurrentSegmentAndAdvance(candidate: candidate, client: client))

        case KeyCode.escape:
            restoreComposingFromSegmentState()
            segmentCandidateCache.removeAll()
            applyMarkedText(candidateText: nil, client: client)
            return (true, .dismiss)

        default:
            if keyCode == KeyCode.backspace {
                restoreComposingFromSegmentState()
                segmentCandidateCache.removeAll()
                applyMarkedText(candidateText: nil, client: client)
                return (true, .dismiss)
            }
            state.segmentState = nil
            segmentCandidateCache.removeAll()
            return (false, .dismiss)
        }
    }

    private mutating func restoreComposingFromSegmentState() {
        guard let ss = state.segmentState else { return }
        state.composedHiragana = ss.convertTarget
        state.segmentState = nil
    }

    mutating func resizeClauseEnd(
        delta: Int,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        guard var ss = state.segmentState else { return (false, .none) }
        syncFocusedSegmentSelection(from: candidate)
        let base = ss.manualClauseEnd ?? ss.effectiveClauseEnd
        let next = max(1, min(ss.convertTarget.count, base + delta))
        guard next != base else { return (true, .none) }

        ss.manualClauseEnd = next
        ss.didExperienceSegmentEdition = true
        ss.rows = refetchEngineRows(for: ss)
        state.segmentState = ss
        state.composedHiragana = ss.convertTarget
        applySegmentMarkedText(client: client)
        return (true, refreshClauseCandidateAction())
    }

    private mutating func refetchEngineRows(for ss: SegmentState) -> [AzooKeyClauseCandidate] {
        let raw = azooKeyConverter.requestConversionResult(
            hiragana: ss.convertTarget,
            leftSideContext: azooKeyLeftContext,
            richCandidates: true
        )
        return AzooKeyCandidateMerge.mergedList(
            result: raw,
            convertTarget: ss.convertTarget,
            segmentEdition: ss.didExperienceSegmentEdition
        )
    }

    mutating func syncFocusedSegmentSelection(from candidate: CandidateContext) {
        guard var ss = state.segmentState, let selectedText = candidate.selectedText else { return }
        if let idx = ss.rows.firstIndex(where: { $0.text == selectedText }) {
            ss.selectedIndex = idx
            state.segmentState = ss
        }
    }

    mutating func confirmCurrentSegmentAndAdvance(
        candidate: CandidateContext,
        client: TextInputClient
    ) -> CandidateAction {
        syncFocusedSegmentSelection(from: candidate)
        guard var ss = state.segmentState else { return .none }

        let clauseEnd = ss.effectiveClauseEnd
        let reading = String(ss.convertTarget.prefix(clauseEnd))
        let text: String
        if let selectedText = candidate.selectedText {
            text = selectedText
        } else if ss.rows.indices.contains(ss.selectedIndex) {
            text = ss.rows[ss.selectedIndex].text
        } else {
            text = reading
        }

        recordClauseLearning(reading: reading, text: text, manuallyAdjusted: ss.didExperienceSegmentEdition)
        insertPartialSegment(text: text, reading: reading, client: client)
        ss.confirmedSegments.append((reading, text))

        let remaining = String(ss.convertTarget.dropFirst(clauseEnd))
        segmentCandidateCache.removeAll()

        if remaining.isEmpty {
            finishSequentialSegmentSession(confirmedSegments: ss.confirmedSegments)
            return .dismiss
        }

        let raw = azooKeyConverter.requestConversionResult(
            hiragana: remaining,
            leftSideContext: azooKeyLeftContext,
            richCandidates: true
        )
        let engineRows = AzooKeyCandidateMerge.mergedList(
            result: raw,
            convertTarget: remaining,
            segmentEdition: false
        )
        ss.convertTarget = remaining
        ss.rows = engineRows.isEmpty
            ? [AzooKeyClauseCandidate(text: remaining, inputLength: remaining.count)]
            : engineRows
        ss.selectedIndex = 0
        ss.manualClauseEnd = nil
        ss.didExperienceSegmentEdition = false
        state.segmentState = ss
        state.composedHiragana = remaining
        applySegmentMarkedText(client: client)
        return refreshClauseCandidateAction()
    }

    mutating func finishSequentialSegmentSession(confirmedSegments: [(reading: String, text: String)]) {
        if confirmedSegments.count >= 2 {
            let fullReading = confirmedSegments.map(\.reading).joined()
            let fullText = confirmedSegments.map(\.text).joined()
            db.recordPrefixes(reading: fullReading, output: fullText)
        }
        state.segmentState = nil
        state.composedHiragana = ""
        state.pendingRomaji = ""
        state.hiddenPendingN = false
    }

    private mutating func recordClauseLearning(reading: String, text: String, manuallyAdjusted: Bool) {
        db.recordPrefixes(reading: reading, output: text)
        let conv = azooKeyConverter
        Task.detached(priority: .utility) { conv.commit(reading: reading, text: text) }
        if manuallyAdjusted {
            db.recordPrefixes(reading: reading, output: text)
        }
    }

    private mutating func insertPartialSegment(text: String, reading: String, client: TextInputClient) {
        let isPunctuation = InputHandler.readingPunctuations.contains(text)
            || InputHandler.sentenceTerminators.contains(text)
        if !isPunctuation && !text.isEmpty {
            appendRecentCommit(reading: reading, output: text)
        }
        if !text.isEmpty {
            if InputHandler.sentenceTerminators.contains(text) {
                if !diaryBuffer.isEmpty {
                    db.recordDailyLog(output: diaryBuffer + text, appBundleID: currentAppBundleID)
                    diaryBuffer = ""
                }
            } else {
                diaryBuffer += text
            }
        }
        pushCommitted(text)
        appendToSessionBuffer(text)
        client.insertText(text)
    }

    mutating func flushSegmentModeComposition(
        candidate: CandidateContext,
        client: TextInputClient
    ) {
        guard var ss = state.segmentState else { return }
        syncFocusedSegmentSelection(from: candidate)

        let clauseEnd = ss.effectiveClauseEnd
        let reading = String(ss.convertTarget.prefix(clauseEnd))
        let text = candidate.selectedText
            ?? (ss.rows.indices.contains(ss.selectedIndex) ? ss.rows[ss.selectedIndex].text : reading)
        recordClauseLearning(reading: reading, text: text, manuallyAdjusted: ss.didExperienceSegmentEdition)
        insertPartialSegment(text: text, reading: reading, client: client)
        ss.confirmedSegments.append((reading, text))

        let remaining = String(ss.convertTarget.dropFirst(clauseEnd))
        if !remaining.isEmpty {
            insertPartialSegment(text: remaining, reading: remaining, client: client)
            ss.confirmedSegments.append((remaining, remaining))
        }

        finishSequentialSegmentSession(confirmedSegments: ss.confirmedSegments)
    }

    func applySegmentMarkedText(client: TextInputClient) {
        guard let segmentState = state.segmentState else { return }
        let str = segmentState.attributedString(overrideFocusedText: nil)
        let focusedLen = segmentState.rows.indices.contains(segmentState.selectedIndex)
            ? segmentState.rows[segmentState.selectedIndex].text.count
            : segmentState.clauseReading.count
        client.setMarkedText(str, selectionRange: NSRange(location: focusedLen, length: 0))
    }

    /// 文節読みに対する履歴・カナ固定・辞書候補（テスト・デバッグ用）。
    func buildSegmentCandidates(reading: String, dictCandidates: [String], prev: String? = nil) -> Segment {
        let hiragana = reading
        let katakana = KanaUtils.hiraganaToKatakana(reading)
        let exactCandidates = db.fetchHistoryExact(reading: reading)
        let prefixCandidates = db.fetchHistoryPrefix(reading: reading)
        let historyCandidates = InputHandler.merged(exactCandidates, prefixCandidates)

        var candidates: [String] = []
        var seen = Set<String>()

        let hiraganaInHistory = historyCandidates.contains(hiragana)
        let katakanaInHistory = historyCandidates.contains(katakana)
        var fixedCount = 0
        if !katakanaInHistory {
            candidates.insert(katakana, at: 0); seen.insert(katakana); fixedCount += 1
        }
        if !hiraganaInHistory && hiragana != katakana {
            candidates.insert(hiragana, at: 0); seen.insert(hiragana); fixedCount += 1
        }

        for h in historyCandidates where seen.insert(h).inserted { candidates.append(h) }
        let historyEnd = fixedCount + historyCandidates.count

        for d in dictCandidates where seen.insert(d).inserted { candidates.append(d) }

        let initialIndex = candidates.count > fixedCount ? fixedCount : 0
        return Segment(
            reading: reading,
            candidates: candidates,
            selectedIndex: initialIndex,
            historyEnd: historyEnd
        )
    }
}
