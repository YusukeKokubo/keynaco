import AppKit

// MARK: - セグメントモード
//
// Space 押下時に AzooKey の変換結果を文節分割してセグメント調整モードへ。
// Shift+矢印で境界を 1 文字単位で動かせる。

extension InputHandler {

    mutating func enterSegmentMode() -> CandidateAction {
        if !state.pendingRomaji.isEmpty {
            state.composedHiragana += RomajiConverter.forceFinalize(state.pendingRomaji)
            state.pendingRomaji = ""
        }
        let rawSegments = azooKeyConverter.segmentize(state.composedHiragana)

        // 1セグメントのみなら従来の候補ウィンドウにフォールバック
        guard rawSegments.count >= 2 else {
            return buildCandidateList()
        }

        let segments = rawSegments.map { buildSegmentCandidates(reading: $0.reading, dictCandidates: $0.candidates) }
        state.segmentState = SegmentState(segments: segments, focusedIndex: 0)
        return makeCandidateActionForFocusedSegment()
    }

    func buildSegmentCandidates(reading: String, dictCandidates: [String]) -> Segment {
        let hiragana = reading
        let katakana = KanaUtils.hiraganaToKatakana(reading)
        let historyCandidates = db.fetchHistoryExact(reading: reading)

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

        for h in historyCandidates where seen.insert(h).inserted { candidates.append(h) }
        let historyEnd = fixedCount + historyCandidates.count

        for d in dictCandidates where seen.insert(d).inserted { candidates.append(d) }

        let initialIndex = candidates.count > fixedCount ? fixedCount : 0
        return Segment(reading: reading, candidates: candidates, selectedIndex: initialIndex, historyEnd: historyEnd)
    }

    func makeCandidateActionForFocusedSegment() -> CandidateAction {
        guard let segmentState = state.segmentState else { return .none }
        let seg = segmentState.focusedSegment
        guard !seg.candidates.isEmpty else { return .dismiss }
        return .show(candidates: seg.candidates, historyEnd: seg.historyEnd, initialRow: seg.selectedIndex)
    }

    mutating func handleSegmentModeKey(
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
            state.segmentState!.focusedIndex += 1
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
            applyMarkedText(candidateText: nil, client: client)
            return (true, .dismiss)

        default:
            if keyCode == KeyCode.backspace {
                state.segmentState = nil
                applyMarkedText(candidateText: nil, client: client)
                return (true, .dismiss)
            }
            // その他のキー → セグメントモード解除してそのキーをスルー
            state.segmentState = nil
            return (false, .dismiss)
        }
    }

    /// Shift+右/左矢印でセグメント境界を1文字単位で調整する。
    /// expand=true: フォーカスセグメントを右に1文字拡張（次セグメントの先頭1文字を奪う）
    /// expand=false: フォーカスセグメントを左に1文字縮小（末尾1文字を次セグメントの先頭に渡す）
    mutating func resizeFocusedSegment(
        expand: Bool,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        guard var segmentState = state.segmentState else { return (false, .none) }
        syncFocusedSegmentSelection(from: candidate)
        let i = segmentState.focusedIndex

        if expand {
            guard i + 1 < segmentState.segments.count else { return (true, .none) }
            let nextReading = segmentState.segments[i + 1].reading
            guard !nextReading.isEmpty else { return (true, .none) }
            let newFocusedReading = segmentState.segments[i].reading + String(nextReading.first!)
            let newNextReading = String(nextReading.dropFirst())
            segmentState.segments[i] = buildSegmentCandidates(
                reading: newFocusedReading,
                dictCandidates: azooKeyConverter.candidatesForSegment(reading:newFocusedReading)
            )
            if newNextReading.isEmpty {
                segmentState.segments.remove(at: i + 1)
            } else {
                segmentState.segments[i + 1] = buildSegmentCandidates(
                    reading: newNextReading,
                    dictCandidates: azooKeyConverter.candidatesForSegment(reading:newNextReading)
                )
            }
        } else {
            let focusedReading = segmentState.segments[i].reading
            guard focusedReading.count >= 2 else { return (true, .none) }
            let newFocusedReading = String(focusedReading.dropLast())
            let removedChar = String(focusedReading.last!)
            segmentState.segments[i] = buildSegmentCandidates(
                reading: newFocusedReading,
                dictCandidates: azooKeyConverter.candidatesForSegment(reading:newFocusedReading)
            )
            if i + 1 < segmentState.segments.count {
                let newNextReading = removedChar + segmentState.segments[i + 1].reading
                segmentState.segments[i + 1] = buildSegmentCandidates(
                    reading: newNextReading,
                    dictCandidates: azooKeyConverter.candidatesForSegment(reading:newNextReading)
                )
            } else {
                segmentState.segments.insert(
                    buildSegmentCandidates(
                        reading: removedChar,
                        dictCandidates: azooKeyConverter.candidatesForSegment(reading:removedChar)
                    ),
                    at: i + 1
                )
            }
        }

        state.segmentState = segmentState
        applySegmentMarkedText(client: client)
        return (true, makeCandidateActionForFocusedSegment())
    }

    mutating func syncFocusedSegmentSelection(from candidate: CandidateContext) {
        guard let segmentState = state.segmentState, let selectedText = candidate.selectedText else { return }
        if let idx = segmentState.focusedSegment.candidates.firstIndex(of: selectedText) {
            state.segmentState!.segments[segmentState.focusedIndex].selectedIndex = idx
        }
    }

    mutating func doConfirmSegments(candidate: CandidateContext, client: TextInputClient) -> CandidateAction {
        syncFocusedSegmentSelection(from: candidate)
        guard let segmentState = state.segmentState else { return .none }
        var confirmed = ""
        for seg in segmentState.segments {
            db.record(input: seg.reading, output: seg.selectedText)
            azooKeyConverter.commit(reading: seg.reading, text: seg.selectedText)
            confirmed += seg.selectedText
        }
        commitText(text: confirmed, client: client)
        return suggestSuccessors()
    }

    func applySegmentMarkedText(client: TextInputClient) {
        guard let segmentState = state.segmentState else { return }
        let str = segmentState.attributedString()
        client.setMarkedText(str, selectionRange: NSRange(location: str.length, length: 0))
    }
}
