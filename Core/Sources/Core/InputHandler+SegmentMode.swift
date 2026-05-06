import AppKit

// MARK: - セグメントモード
//
// Space 押下時に AzooKey の変換結果を文節分割してセグメント調整モードへ。
// Shift+矢印で境界を 1 文字単位で動かせる。

public extension InputHandler {

    public mutating func enterSegmentMode() -> CandidateAction {
        if !state.pendingRomaji.isEmpty {
            state.composedHiragana += RomajiConverter.forceFinalize(state.pendingRomaji)
            state.pendingRomaji = ""
        }
        let fullReading = state.composedHiragana

        // 全 ASCII（数字・英単語）はセグメント変換しない。
        // ASCII 読みを segmentize すると履歴の断片が誤結合して "23456" → "2345656六" のような
        // 不正な確定になる。buildCandidateList の ASCII ガードとここで一貫させる。
        if fullReading.allSatisfy({ $0.isASCII }) {
            return buildCandidateList()
        }

        let segments: [Segment]
        if let stored = db.fetchBoundaryPref(fullReading: fullReading), stored.count >= 2 {
            var built: [Segment] = []
            var prevText: String? = lastCommittedOutput
            for reading in stored {
                let seg = buildSegmentCandidates(
                    reading: reading,
                    dictCandidates: azooKeyConverter.candidatesForSegment(reading: reading, leftSideContext: azooKeyLeftContext),
                    prev: prevText
                )
                built.append(seg)
                prevText = seg.selectedText
            }
            segments = built
        } else {
            let rawSegments = azooKeyConverter.segmentize(fullReading, leftSideContext: azooKeyLeftContext)
            guard rawSegments.count >= 2 else {
                return buildCandidateList()
            }
            var built: [Segment] = []
            var prevText: String? = lastCommittedOutput
            for raw in rawSegments {
                let seg = buildSegmentCandidates(reading: raw.reading, dictCandidates: raw.candidates, prev: prevText)
                built.append(seg)
                prevText = seg.selectedText
            }
            segments = built
        }

        state.segmentState = SegmentState(segments: segments, focusedIndex: 0)
        segmentLLMTrigger = .start(hiragana: fullReading)
        return makeCandidateActionForFocusedSegment()
    }

    /// `LLMSegmentConverter` の結果を文節境界推定に成功すれば再構築、失敗時は先頭文節に全文候補を挿入（`InputController` から呼ぶ）。
    public mutating func applyLLMSegmentResult(text raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard var ss = state.segmentState, ss.llmWholeText == nil else { return }
        let fullReading = ss.segments.map(\.reading).joined()
        guard fullReading == state.composedHiragana else { return }
        if text == fullReading { return }
        if text == ss.allSelectedText { return }
        guard !ss.segments.isEmpty else { return }

        let baseline = ss.segments.map(\.reading)
        if let pairs = LLMSegmentConverter.inferSegmentBoundaries(
            hiragana: fullReading,
            llmText: text,
            azooKey: azooKeyConverter,
            baselineSegmentReadings: baseline,
            leftSideContext: azooKeyLeftContext
        ) {
            applyLLMBoundaries(pairs: pairs, llmWholeText: text)
            return
        }

        // Zenzai 有効時は segmentize / candidatesForSegment ベースの候補を維持し、全文挿入フォールバックしない。
        if azooKeyConverter.isZenzaiEnabled { return }

        if ss.segments[0].candidates.contains(text) { return }

        ss.segments[0].candidates.insert(text, at: 0)
        ss.segments[0].historyEnd += 1
        let newCount = ss.segments[0].candidates.count
        ss.segments[0].selectedIndex = min(ss.segments[0].selectedIndex + 1, newCount - 1)
        ss.llmWholeText = text
        state.segmentState = ss
    }

    private mutating func applyLLMBoundaries(pairs: [(reading: String, token: String)], llmWholeText: String) {
        let zenzaiOn = azooKeyConverter.isZenzaiEnabled
        var built: [Segment] = []
        for i in pairs.indices {
            let reading = pairs[i].reading
            let token = pairs[i].token
            let prev: String? = (i == 0) ? lastCommittedOutput : pairs[i - 1].token
            let dictCandidates = azooKeyConverter.candidatesForSegment(reading: reading, leftSideContext: azooKeyLeftContext)
            var seg = buildSegmentCandidates(reading: reading, dictCandidates: dictCandidates, prev: prev)
            let zenTop = dictCandidates.first

            if zenzaiOn, let z = zenTop, z != token, seg.candidates.contains(z) {
                Self.reorderSegmentCandidatesZenzaiBeforeLLM(segment: &seg, zenTop: z, token: token)
            } else if let idx = seg.candidates.firstIndex(of: token) {
                if idx != 0 {
                    seg.candidates.remove(at: idx)
                    seg.candidates.insert(token, at: 0)
                }
                let newCount = seg.candidates.count
                seg.selectedIndex = min(seg.selectedIndex + 1, newCount - 1)
            } else {
                seg.candidates.insert(token, at: 0)
                seg.historyEnd += 1
                let newCount = seg.candidates.count
                seg.selectedIndex = min(seg.selectedIndex + 1, newCount - 1)
            }
            built.append(seg)
        }
        if pairs.count >= 2 {
            for i in built.indices {
                built[i].selectedIndex = 0
            }
        }
        var newState = SegmentState(segments: built, focusedIndex: 0)
        newState.llmWholeText = llmWholeText
        newState.isLlmBoundaryInferred = pairs.count >= 2
        state.segmentState = newState
        segmentCandidateCache.removeAll()
    }

    /// LLM 全文一発確定: 以下のいずれかを満たすとき。
    /// - 多文節境界パス: 全文節が先頭候補選択かつ連結が llmWholeText と一致
    /// - 旧フォールバックパス: focusedSegment の candidates[0] が llmWholeText そのもの
    public func isLlmWholeTextShortcut(segmentState: SegmentState, candidateSelectedText: String?) -> Bool {
        guard let whole = segmentState.llmWholeText else { return false }
        guard segmentState.focusedIndex == 0 else { return false }
        guard !segmentState.segments.isEmpty else { return false }
        let focused = segmentState.focusedSegment
        guard !focused.candidates.isEmpty else { return false }
        let effective = candidateSelectedText ?? focused.selectedText

        // 多文節境界パス: applyLLMBoundaries が全文節を再構築している
        if segmentState.segments.allSatisfy({ !$0.candidates.isEmpty && $0.selectedIndex == 0 }),
           segmentState.segments.map({ $0.candidates[0] }).joined() == whole {
            return effective == focused.candidates[0]
        }

        // 旧フォールバックパス: LLM 全文が segments[0].candidates[0] にのみ挿入されている
        if focused.candidates[0] == whole {
            return focused.selectedIndex == 0 && effective == whole
        }

        return false
    }

    public func buildSegmentCandidates(reading: String, dictCandidates: [String], prev: String? = nil) -> Segment {
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
        // hiragana == katakana（非ひらがな文字）の場合は重複挿入しない
        if !hiraganaInHistory && hiragana != katakana {
            candidates.insert(hiragana, at: 0); seen.insert(hiragana); fixedCount += 1
        }

        var bigramCount = 0
        if let p = prev {
            for b in db.fetchBigram(prev: p, reading: reading) where seen.insert(b).inserted {
                candidates.append(b)
                bigramCount += 1
            }
        }

        for h in historyCandidates where seen.insert(h).inserted { candidates.append(h) }
        let historyEnd = fixedCount + bigramCount + historyCandidates.count

        for d in dictCandidates where seen.insert(d).inserted { candidates.append(d) }

        let initialIndex = candidates.count > fixedCount ? fixedCount : 0
        return Segment(reading: reading, candidates: candidates, selectedIndex: initialIndex, historyEnd: historyEnd)
    }

    public mutating func buildSegmentCandidatesCached(reading: String, dictCandidates: [String], prev: String? = nil) -> Segment {
        let cacheKey = "\(reading)|\(prev ?? "")"
        if let cached = segmentCandidateCache[cacheKey] { return cached }
        let result = buildSegmentCandidates(reading: reading, dictCandidates: dictCandidates, prev: prev)
        segmentCandidateCache[cacheKey] = result
        return result
    }

    public func makeCandidateActionForFocusedSegment() -> CandidateAction {
        guard let segmentState = state.segmentState else { return .none }
        let seg = segmentState.focusedSegment
        guard !seg.candidates.isEmpty else { return .dismiss }
        return .show(candidates: seg.candidates, historyEnd: seg.historyEnd, initialRow: seg.selectedIndex, predictionEnd: seg.historyEnd, fixedEnd: 0)
    }

    public mutating func handleSegmentModeKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        guard let segmentState = state.segmentState else { return (false, .none) }

        switch keyCode {
        case KeyCode.leftArrow:
            if modifiers.contains(.shift) {
                return resizeFocusedSegment(expand: false, candidate: candidate, client: client)
            }
            guard segmentState.focusedIndex > 0 else { return (true, .none) }
            syncFocusedSegmentSelection(from: candidate)
            state.segmentState!.focusedIndex -= 1
            applySegmentMarkedText(client: client)
            return (true, makeCandidateActionForFocusedSegment())

        case KeyCode.rightArrow:
            if modifiers.contains(.shift) {
                return resizeFocusedSegment(expand: true, candidate: candidate, client: client)
            }
            guard segmentState.focusedIndex < segmentState.segments.count - 1 else { return (true, .none) }
            syncFocusedSegmentSelection(from: candidate)
            let newIndex = segmentState.focusedIndex + 1
            let prevText = state.segmentState!.segments[segmentState.focusedIndex].selectedText
            let nextSeg = segmentState.segments[newIndex]
            state.segmentState!.segments[newIndex] = buildSegmentCandidates(
                reading: nextSeg.reading,
                dictCandidates: azooKeyConverter.candidatesForSegment(reading: nextSeg.reading, leftSideContext: azooKeyLeftContext),
                prev: prevText
            )
            state.segmentState!.focusedIndex = newIndex
            applySegmentMarkedText(client: client)
            return (true, makeCandidateActionForFocusedSegment())

        case KeyCode.space, KeyCode.tab, KeyCode.downArrow:
            return (true, .selectNext)

        case KeyCode.upArrow:
            return (true, .selectPrev)

        case KeyCode.enter:
            return (true, doConfirmSegments(candidate: candidate, client: client))

        case KeyCode.escape:
            state.segmentState = nil
            segmentCandidateCache.removeAll()
            segmentLLMTrigger = .none
            applyMarkedText(candidateText: nil, client: client)
            return (true, .dismiss)

        default:
            if keyCode == KeyCode.backspace {
                state.segmentState = nil
                segmentCandidateCache.removeAll()
                segmentLLMTrigger = .none
                applyMarkedText(candidateText: nil, client: client)
                return (true, .dismiss)
            }
            // その他のキー → セグメントモード解除してそのキーをスルー
            state.segmentState = nil
            segmentCandidateCache.removeAll()
            segmentLLMTrigger = .none
            return (false, .dismiss)
        }
    }

    /// Shift+右/左矢印でセグメント境界を1文字単位で調整する。
    /// expand=true: フォーカスセグメントを右に1文字拡張（次セグメントの先頭1文字を奪う）
    /// expand=false: フォーカスセグメントを左に1文字縮小（末尾1文字を次セグメントの先頭に渡す）
    public mutating func resizeFocusedSegment(
        expand: Bool,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        guard var segmentState = state.segmentState else { return (false, .none) }
        syncFocusedSegmentSelection(from: candidate)
        let i = segmentState.focusedIndex

        let focusedPrev: String? = i > 0 ? segmentState.segments[i - 1].selectedText : lastCommittedOutput

        if expand {
            guard i + 1 < segmentState.segments.count else { return (true, .none) }
            let nextReading = segmentState.segments[i + 1].reading
            guard !nextReading.isEmpty else { return (true, .none) }
            let newFocusedReading = segmentState.segments[i].reading + String(nextReading.first!)
            let newNextReading = String(nextReading.dropFirst())
            var rebuilt = buildSegmentCandidatesCached(
                reading: newFocusedReading,
                dictCandidates: azooKeyConverter.candidatesForSegment(reading: newFocusedReading, leftSideContext: azooKeyLeftContext),
                prev: focusedPrev
            )
            rebuilt.isManuallyAdjusted = true
            segmentState.segments[i] = rebuilt
            if newNextReading.isEmpty {
                segmentState.segments.remove(at: i + 1)
            } else {
                segmentState.segments[i + 1] = buildSegmentCandidatesCached(
                    reading: newNextReading,
                    dictCandidates: azooKeyConverter.candidatesForSegment(reading: newNextReading, leftSideContext: azooKeyLeftContext),
                    prev: rebuilt.selectedText
                )
            }
        } else {
            let focusedReading = segmentState.segments[i].reading
            guard focusedReading.count >= 2 else { return (true, .none) }
            let newFocusedReading = String(focusedReading.dropLast())
            let removedChar = String(focusedReading.last!)
            var rebuilt = buildSegmentCandidatesCached(
                reading: newFocusedReading,
                dictCandidates: azooKeyConverter.candidatesForSegment(reading: newFocusedReading, leftSideContext: azooKeyLeftContext),
                prev: focusedPrev
            )
            rebuilt.isManuallyAdjusted = true
            segmentState.segments[i] = rebuilt
            if i + 1 < segmentState.segments.count {
                let newNextReading = removedChar + segmentState.segments[i + 1].reading
                segmentState.segments[i + 1] = buildSegmentCandidatesCached(
                    reading: newNextReading,
                    dictCandidates: azooKeyConverter.candidatesForSegment(reading: newNextReading, leftSideContext: azooKeyLeftContext),
                    prev: rebuilt.selectedText
                )
            } else {
                segmentState.segments.insert(
                    buildSegmentCandidatesCached(
                        reading: removedChar,
                        dictCandidates: azooKeyConverter.candidatesForSegment(reading: removedChar, leftSideContext: azooKeyLeftContext),
                        prev: rebuilt.selectedText
                    ),
                    at: i + 1
                )
            }
        }

        state.segmentState = segmentState
        applySegmentMarkedText(client: client)
        return (true, makeCandidateActionForFocusedSegment())
    }

    public mutating func syncFocusedSegmentSelection(from candidate: CandidateContext) {
        guard let segmentState = state.segmentState, let selectedText = candidate.selectedText else { return }
        if let idx = segmentState.focusedSegment.candidates.firstIndex(of: selectedText) {
            state.segmentState!.segments[segmentState.focusedIndex].selectedIndex = idx
        }
    }

    public mutating func doConfirmSegments(candidate: CandidateContext, client: TextInputClient) -> CandidateAction {
        syncFocusedSegmentSelection(from: candidate)
        guard let segmentState = state.segmentState else { return .none }

        if let llmText = segmentState.llmWholeText,
           isLlmWholeTextShortcut(segmentState: segmentState, candidateSelectedText: candidate.selectedText) {
            let fullReading = segmentState.segments.map(\.reading).joined()
            if segmentState.isLlmBoundaryInferred {
                db.saveBoundaryPref(
                    fullReading: fullReading,
                    segments: segmentState.segments.map(\.reading)
                )
            }
            state.segmentState = nil
            segmentCandidateCache.removeAll()
            segmentLLMTrigger = .none
            db.recordPrefixes(reading: fullReading, output: llmText)
            azooKeyConverter.commit(reading: fullReading, text: llmText)
            commitText(text: llmText, fullReading: fullReading, client: client)
            return suggestSuccessors()
        }

        var confirmed = ""
        var fullReading = ""
        for seg in segmentState.segments {
            db.recordPrefixes(reading: seg.reading, output: seg.selectedText)
            let conv = azooKeyConverter; let r = seg.reading; let t = seg.selectedText
            Task.detached(priority: .utility) { conv.commit(reading: r, text: t) }
            if seg.isManuallyAdjusted {
                db.recordPrefixes(reading: seg.reading, output: seg.selectedText)
                db.recordPrefixes(reading: seg.reading, output: seg.selectedText)
            }
            confirmed += seg.selectedText
            fullReading += seg.reading
        }
        if segmentState.segments.count >= 2 {
            db.recordPrefixes(reading: fullReading, output: confirmed)
        }
        let segs = segmentState.segments
        for i in 0..<segs.count - 1 {
            let prevSeg = segs[i]
            let next = segs[i + 1]
            db.recordBigram(prev: prevSeg.selectedText, input: next.reading, output: next.selectedText)
            if next.isManuallyAdjusted || prevSeg.isManuallyAdjusted {
                db.recordBigram(prev: prevSeg.selectedText, input: next.reading, output: next.selectedText)
                db.recordBigram(prev: prevSeg.selectedText, input: next.reading, output: next.selectedText)
            }
        }
        if segs.contains(where: { $0.isManuallyAdjusted }) || segmentState.isLlmBoundaryInferred {
            db.saveBoundaryPref(fullReading: fullReading, segments: segs.map { $0.reading })
        }
        segmentLLMTrigger = .none
        commitText(text: confirmed, fullReading: fullReading, client: client)
        return suggestSuccessors()
    }

    public func applySegmentMarkedText(client: TextInputClient) {
        guard let segmentState = state.segmentState else { return }
        let str = segmentState.attributedString()
        client.setMarkedText(str, selectionRange: NSRange(location: str.length, length: 0))
    }

    /// Zenzai 有効かつ `zenTop != token` のとき、辞書先頭表層を LLM トークンより前に並べ替える（`candidatesForSegment` の先頭は `zenTop` と一致し候補列に含まれること）。
    private static func reorderSegmentCandidatesZenzaiBeforeLLM(segment: inout Segment, zenTop: String, token: String) {
        func remove(_ s: String) {
            guard let idx = segment.candidates.firstIndex(of: s) else { return }
            if idx < segment.historyEnd {
                segment.historyEnd -= 1
            }
            segment.candidates.remove(at: idx)
        }

        let ti = segment.candidates.firstIndex(of: token)
        let zi = segment.candidates.firstIndex(of: zenTop)
        if let ti = ti, let zi = zi {
            if ti > zi {
                remove(token)
                remove(zenTop)
            } else {
                remove(zenTop)
                remove(token)
            }
        } else if ti != nil {
            remove(token)
            if segment.candidates.contains(zenTop) {
                remove(zenTop)
            }
        } else if zi != nil {
            remove(zenTop)
        }

        segment.candidates.insert(zenTop, at: 0)
        if zenTop != token {
            segment.candidates.insert(token, at: 1)
        }

        // `remove()` が `idx < historyEnd` なら都度 -1 済み。先頭へ zenTop/token を2行挿入するので、履歴境界 index は常に +2
        //（`netInserted == 1` のように見えるケースでも、新規 token のみ +1 では履歴行の index が足りず Shift+Delete 範囲が壊れる）。
        segment.historyEnd += 2

        segment.selectedIndex = 0
    }
}
