import AppKit

// MARK: - セグメントモード
//
// Space 押下時に AzooKey の segmentize で左端文節を切り出し、
// Enter で 1 文節ずつ確定 → 残りを再 segmentize する（AzooKey 準拠の逐次フロー）。
// Shift+矢印で現在文節と残り読みの境界を 1 文字単位で調整できる。

public extension InputHandler {

    mutating func enterSegmentMode() -> CandidateAction {
        state.absorbPendingIntoComposed()
        let fullReading = state.composedHiragana

        if fullReading.allSatisfy({ $0.isASCII }) {
            return buildCandidateList()
        }

        guard let initial = makeInitialSegmentState(fullReading: fullReading) else {
            let listAction = buildCandidateList()
            if case .show(let candidates, let historyEnd, _, _, _) = listAction,
               candidates.count > historyEnd {
                return listAction
            }
            return listAction
        }

        state.segmentState = initial
        state.composedHiragana = initial.pendingReading
        return makeCandidateActionForFocusedSegment()
    }

    /// 読み全体から左端 1 文節 + 残りを構築する。分割不能なら nil。
    private mutating func makeInitialSegmentState(fullReading: String) -> SegmentState? {
        let rawSegments = azooKeyConverter.segmentize(fullReading, leftSideContext: azooKeyLeftContext)
        if rawSegments.count >= 2 {
            let first = rawSegments[0]
            var remaining = String(fullReading.dropFirst(first.reading.count))
            var current = buildSegmentCandidates(
                reading: first.reading,
                dictCandidates: first.candidates,
                prev: lastCommittedOutput
            )
            // 促音終わり誤分割の修正（2 分割時のみ）
            if rawSegments.count == 2, rawSegments[0].reading.last == "っ",
               let manualSegs = tryManualBisection(fullReading: fullReading),
               manualSegs[0].reading.count > rawSegments[0].reading.count {
                current = manualSegs[0]
                remaining = manualSegs[1].reading
            }
            return SegmentState(current: current, remainingReading: remaining)
        }
        if let manualSegs = tryManualBisection(fullReading: fullReading) {
            return SegmentState(current: manualSegs[0], remainingReading: manualSegs[1].reading)
        }
        return nil
    }

    /// 残り読みから左端 1 文節 + 残りを構築する（逐次確定後の再分割）。
    private mutating func makeNextSegmentState(
        remainingReading: String,
        prevText: String,
        confirmedSegments: [(reading: String, text: String)]
    ) -> SegmentState {
        let raw = azooKeyConverter.segmentize(remainingReading, leftSideContext: azooKeyLeftContext)
        let firstReading: String
        let dictCandidates: [String]
        if let first = raw.first {
            firstReading = first.reading
            dictCandidates = first.candidates
        } else {
            firstReading = remainingReading
            dictCandidates = []
        }
        let tail = String(remainingReading.dropFirst(firstReading.count))
        let current = buildSegmentCandidates(
            reading: firstReading,
            dictCandidates: dictCandidates,
            prev: prevText
        )
        return SegmentState(
            current: current,
            remainingReading: tail,
            confirmedSegments: confirmedSegments
        )
    }

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
        return Segment(reading: reading, candidates: candidates, selectedIndex: initialIndex, historyEnd: historyEnd)
    }

    mutating func buildSegmentCandidatesCached(reading: String, dictCandidates: [String], prev: String? = nil) -> Segment {
        let cacheKey = "\(reading)|\(prev ?? "")"
        if let cached = segmentCandidateCache[cacheKey] { return cached }
        let result = buildSegmentCandidates(reading: reading, dictCandidates: dictCandidates, prev: prev)
        segmentCandidateCache[cacheKey] = result
        return result
    }

    func makeCandidateActionForFocusedSegment() -> CandidateAction {
        guard let segmentState = state.segmentState else { return .none }
        let seg = segmentState.current
        guard !seg.candidates.isEmpty else { return .dismiss }
        return .show(candidates: seg.candidates, historyEnd: seg.historyEnd, initialRow: seg.selectedIndex, predictionEnd: seg.historyEnd, fixedEnd: 0)
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
                return resizeCurrentSegment(expand: false, candidate: candidate, client: client)
            }
            return (true, .none)

        case KeyCode.rightArrow:
            if modifiers.contains(.shift) {
                return resizeCurrentSegment(expand: true, candidate: candidate, client: client)
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

    /// Escape / Backspace 時: 確定済みテキストはそのまま、未確定読みだけ組成中へ戻す。
    private mutating func restoreComposingFromSegmentState() {
        guard let ss = state.segmentState else { return }
        state.composedHiragana = ss.pendingReading
        state.segmentState = nil
    }

    /// Shift+右/左矢印で現在文節と残り読みの境界を 1 文字調整する。
    mutating func resizeCurrentSegment(
        expand: Bool,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        guard var ss = state.segmentState else { return (false, .none) }
        syncFocusedSegmentSelection(from: candidate)
        let prevText = ss.confirmedSegments.last?.text ?? lastCommittedOutput

        if expand {
            guard !ss.remainingReading.isEmpty else { return (true, .none) }
            let nextChar = ss.remainingReading.first!
            ss.remainingReading = String(ss.remainingReading.dropFirst())
            let newReading = ss.current.reading + String(nextChar)
            var rebuilt = buildSegmentCandidatesCached(
                reading: newReading,
                dictCandidates: azooKeyConverter.candidatesForSegment(reading: newReading, leftSideContext: azooKeyLeftContext),
                prev: prevText
            )
            rebuilt.isManuallyAdjusted = true
            ss.current = rebuilt
        } else {
            guard ss.current.reading.count >= 2 else { return (true, .none) }
            let removedChar = ss.current.reading.last!
            let newReading = String(ss.current.reading.dropLast())
            var rebuilt = buildSegmentCandidatesCached(
                reading: newReading,
                dictCandidates: azooKeyConverter.candidatesForSegment(reading: newReading, leftSideContext: azooKeyLeftContext),
                prev: prevText
            )
            rebuilt.isManuallyAdjusted = true
            ss.current = rebuilt
            ss.remainingReading = String(removedChar) + ss.remainingReading
        }

        state.segmentState = ss
        state.composedHiragana = ss.pendingReading
        applySegmentMarkedText(client: client)
        return (true, makeCandidateActionForFocusedSegment())
    }

    mutating func syncFocusedSegmentSelection(from candidate: CandidateContext) {
        guard let segmentState = state.segmentState, let selectedText = candidate.selectedText else { return }
        if let idx = segmentState.current.candidates.firstIndex(of: selectedText) {
            state.segmentState!.current.selectedIndex = idx
        }
    }

    /// 左端文節を確定して insert し、残りがあれば再 segmentize して続行する。
    mutating func confirmCurrentSegmentAndAdvance(
        candidate: CandidateContext,
        client: TextInputClient
    ) -> CandidateAction {
        syncFocusedSegmentSelection(from: candidate)
        guard var ss = state.segmentState else { return .none }

        let seg = ss.current
        recordSegmentLearning(seg)
        insertPartialSegment(text: seg.selectedText, reading: seg.reading, client: client)
        ss.confirmedSegments.append((seg.reading, seg.selectedText))
        segmentCandidateCache.removeAll()

        let remaining = ss.remainingReading
        if remaining.isEmpty {
            finishSequentialSegmentSession(confirmedSegments: ss.confirmedSegments)
            return .dismiss
        }

        let next = makeNextSegmentState(
            remainingReading: remaining,
            prevText: seg.selectedText,
            confirmedSegments: ss.confirmedSegments
        )
        state.segmentState = next
        state.composedHiragana = next.pendingReading
        applySegmentMarkedText(client: client)
        return makeCandidateActionForFocusedSegment()
    }

    /// 逐次確定の最後: フレーズ学習してセグメントモードを終了する。
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

    private mutating func recordSegmentLearning(_ seg: Segment) {
        db.recordPrefixes(reading: seg.reading, output: seg.selectedText)
        let conv = azooKeyConverter
        let r = seg.reading
        let t = seg.selectedText
        Task.detached(priority: .utility) { conv.commit(reading: r, text: t) }
        if seg.isManuallyAdjusted {
            db.recordPrefixes(reading: seg.reading, output: seg.selectedText)
        }
    }

    /// 1 文節分だけ insert する（CompositionState は維持）。
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

    /// 強制確定（deactivateServer 等）: 現在文節 + 残り読みをまとめて確定する。
    mutating func flushSegmentModeComposition(
        candidate: CandidateContext,
        client: TextInputClient
    ) {
        guard var ss = state.segmentState else { return }
        syncFocusedSegmentSelection(from: candidate)

        recordSegmentLearning(ss.current)
        insertPartialSegment(text: ss.current.selectedText, reading: ss.current.reading, client: client)
        ss.confirmedSegments.append((ss.current.reading, ss.current.selectedText))

        if !ss.remainingReading.isEmpty {
            insertPartialSegment(text: ss.remainingReading, reading: ss.remainingReading, client: client)
            ss.confirmedSegments.append((ss.remainingReading, ss.remainingReading))
        }

        finishSequentialSegmentSession(confirmedSegments: ss.confirmedSegments)
    }

    func applySegmentMarkedText(client: TextInputClient) {
        guard let segmentState = state.segmentState else { return }
        let str = segmentState.attributedString()
        client.setMarkedText(str, selectionRange: NSRange(location: str.length, length: 0))
    }

    func tryManualBisection(fullReading: String) -> [Segment]? {
        let chars = Array(fullReading)
        guard chars.count >= 4 else { return nil }
        for i in 1..<chars.count - 1 {
            let front = String(chars[..<i])
            let back = String(chars[i...])
            let frontCands = azooKeyConverter.requestCandidates(hiragana: front, leftSideContext: azooKeyLeftContext, richCandidates: false)
            guard frontCands.first.map(Self.isValidWordCandidate) == true else { continue }
            let backCands = azooKeyConverter.requestCandidates(hiragana: back, leftSideContext: azooKeyLeftContext, richCandidates: false)
            guard backCands.first.map(Self.isValidWordCandidate) == true else { continue }
            let frontDict = azooKeyConverter.candidatesForSegment(reading: front, leftSideContext: azooKeyLeftContext)
            let backDict = azooKeyConverter.candidatesForSegment(reading: back, leftSideContext: azooKeyLeftContext)
            let frontSeg = buildSegmentCandidates(reading: front, dictCandidates: frontDict, prev: lastCommittedOutput)
            let backSeg = buildSegmentCandidates(reading: back, dictCandidates: backDict, prev: frontSeg.selectedText)
            return [frontSeg, backSeg]
        }
        return nil
    }

    private static func isValidWordCandidate(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        let v = first.value
        guard !(0x3041...0x3096 ~= v) && !(0x30A1...0x30F6 ~= v) else { return false }
        let smallKana: Set<Character> = ["っ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゃ", "ゅ", "ょ", "ゎ", "ッ", "ァ", "ィ", "ゥ", "ェ", "ォ", "ャ", "ュ", "ョ", "ヮ"]
        guard let last = s.last else { return false }
        return !smallKana.contains(last)
    }
}
