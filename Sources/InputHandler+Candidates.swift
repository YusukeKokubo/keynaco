import AppKit

// MARK: - 候補リスト構築・候補表示中・通常入力
//
// `handle()` の主要分岐 3 つ：
//   - handleCandidateVisible  : 候補ウィンドウ表示中のキー
//   - handleNormalInput       : 通常の文字入力（ローマ字・Shift・記号）
//   - buildCandidateList      : 候補列の組み立て（履歴・bi-gram・azooKey 統合）
//   - doConfirmSelection      : Enter による候補確定

extension InputHandler {

    @discardableResult
    mutating func doConfirmSelection(candidate: CandidateContext, client: TextInputClient) -> CandidateAction {
        guard !state.composingText.isEmpty else { return .none }
        let inputKey = state.finalizedText
        let normalizedInput = inputKey.allSatisfy({ $0.isASCII }) ? inputKey.lowercased() : inputKey
        // Enter キーによる確定: 視覚的に選択中の候補をそのまま確定する
        if let selected = candidate.selectedText {
            db.recordPrefixes(reading: normalizedInput, output: selected)
            azooKeyConverter.commit(reading: inputKey, text: selected)
            commitText(text: selected, client: client)
        } else {
            commitComposition(client: client)
        }
        return suggestSuccessors()
    }

    mutating func handleCandidateVisible(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        let isBackspace = keyCode == KeyCode.backspace || characters == "\u{08}"
        switch keyCode {
        case KeyCode.tab where modifiers.contains(.shift):
            return (true, .selectPrev)
        case KeyCode.space:
            if !state.composedHiragana.isEmpty {
                let action = enterSegmentMode()
                if state.isSegmentMode {
                    applySegmentMarkedText(client: client)
                } else {
                    applyMarkedText(candidateText: nil, client: client)
                }
                return (true, action)
            }
            return (true, .selectNext)
        case KeyCode.tab, KeyCode.downArrow:
            return (true, .selectNext)
        case KeyCode.upArrow:
            return (true, .selectPrev)
        case KeyCode.enter:
            return (true, doConfirmSelection(candidate: candidate, client: client))
        case KeyCode.escape:
            return doEscape(client: client)
        case KeyCode.rightArrow:
            commitComposition(client: client)
            return (true, suggestSuccessors())
        case KeyCode.backspace where modifiers.contains(.shift):
            if candidate.selectedRow < candidate.historyEnd { return (true, .deleteSelected) }
            return (true, .none)
        default:
            if isBackspace { return doBackspace(client: client) }
            return nil
        }
    }

    mutating func handleNormalInput(
        keyCode: UInt16,
        characters: String?,
        baseCharacters: String?,
        modifiers: NSEvent.ModifierFlags,
        wasExplicitlySelected: Bool,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        if keyCode == KeyCode.space {
            if !state.composedHiragana.isEmpty {
                let action = enterSegmentMode()
                if state.isSegmentMode {
                    applySegmentMarkedText(client: client)
                } else {
                    applyMarkedText(candidateText: nil, client: client)
                }
                return (true, action)
            }
            return (false, .none)
        }

        if keyCode >= KeyCode.leftArrow && keyCode <= KeyCode.upArrow { return (false, .none) }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return (false, .none) }
        guard let chars = characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return (false, .none) }
        let base = baseCharacters ?? chars

        let punctuationMap: [String: String] = [",": "、", ".": "。"]
        if let mappedPunct = punctuationMap[base], !modifiers.contains(.shift) {
            if state.composingText.isEmpty {
                client.insertText(mappedPunct)
                return (true, .dismiss)
            } else {
                if !state.pendingRomaji.isEmpty {
                    state.composedHiragana += RomajiConverter.forceFinalize(state.pendingRomaji)
                    state.pendingRomaji = ""
                }
                state.composedHiragana += mappedPunct
                let action = buildCandidateList()
                applyMarkedText(candidateText: nil, client: client)
                return (true, action)
            }
        }

        let isNonAscii = chars.unicodeScalars.contains(where: { $0.value >= 0x80 })

        if modifiers.contains(.shift) && !isNonAscii {
            if wasExplicitlySelected {
                _ = doConfirmSelection(candidate: candidate, client: client)
            } else if !state.pendingRomaji.isEmpty {
                state.composedHiragana += RomajiConverter.forceFinalize(state.pendingRomaji)
                state.pendingRomaji = ""
            }
            state.composedHiragana += chars
            let action = buildCandidateList(autoShow: true)
            applyMarkedText(candidateText: nil, client: client)
            return (true, action)
        }

        if isNonAscii {
            if state.composingText.isEmpty {
                client.insertText(chars)
            } else {
                if !state.pendingRomaji.isEmpty {
                    state.composedHiragana += RomajiConverter.forceFinalize(state.pendingRomaji)
                    state.pendingRomaji = ""
                }
                state.composedHiragana += chars
                applyMarkedText(candidateText: nil, client: client)
            }
            return (true, .dismiss)
        }

        if !state.composedHiragana.isEmpty && state.pendingRomaji.isEmpty
            && state.composedHiragana.allSatisfy({ $0.isASCII }) {
            if wasExplicitlySelected {
                _ = doConfirmSelection(candidate: candidate, client: client)
            }
            state.composedHiragana += chars
            let action = buildCandidateList(autoShow: true)
            applyMarkedText(candidateText: nil, client: client)
            return (true, action)
        }

        if wasExplicitlySelected {
            _ = doConfirmSelection(candidate: candidate, client: client)
        }
        let needsRefresh = state.addRomaji(base)
        let hasBigramContext = lastCommittedOutput != nil && !state.composedHiragana.isEmpty
        let candidateAction: CandidateAction = (needsRefresh || hasBigramContext) ? buildCandidateList(autoShow: true) : .dismiss
        applyMarkedText(candidateText: nil, client: client)
        return (true, candidateAction)
    }

    /// - Parameter autoShow: 文字入力中の自動表示（true）か Space など明示トリガー（false）か。
    ///   autoShow=true のとき履歴も辞書候補もなければ表示しない。
    mutating func buildCandidateList(autoShow: Bool = false) -> CandidateAction {
        let h = state.composedHiragana
        let azooKeyCandidates = h.allSatisfy({ $0.isASCII }) ? [] : azooKeyConverter.requestCandidates(hiragana: h)
        let historyKey = (!h.isEmpty && h.allSatisfy({ $0.isASCII })) ? h.lowercased() : h
        let exactCandidates = db.fetchHistoryExact(reading: historyKey)
        let prefixCandidates = db.fetchHistoryPrefix(reading: historyKey)
        let historyCandidates = exactCandidates + prefixCandidates.filter { !exactCandidates.contains($0) }
        let historyCount = historyCandidates.count

        let bigramRaw = lastCommittedOutput.map { db.fetchBigram(prev: $0, reading: state.composedHiragana) } ?? []
        let trigramRaw: [String] = {
            guard let p1 = lastCommittedOutput, let p2 = prev2Output else { return [] }
            return db.fetchTrigram(prev2: p2, prev1: p1, reading: state.composedHiragana)
        }()
        let skipBigramRaw = mostRecentContentWord().map { db.fetchSkipBigram(prev: $0, reading: state.composedHiragana) } ?? []
        let predictRaw = trigramRaw + bigramRaw.filter { !trigramRaw.contains($0) }
            + skipBigramRaw.filter { !trigramRaw.contains($0) && !bigramRaw.contains($0) }
        var candidates = historyCandidates + azooKeyCandidates.filter { !historyCandidates.contains($0) }
        let uniquePredictions = predictRaw.filter { !candidates.contains($0) }
        candidates.insert(contentsOf: uniquePredictions, at: 0)
        let predictCount = uniquePredictions.count

        if autoShow && historyCount == 0 && azooKeyCandidates.isEmpty && predictCount == 0 { return .dismiss }

        let hiragana = state.composedHiragana
        let katakana = KanaUtils.hiraganaToKatakana(hiragana)

        // 履歴にひらがな・カタカナが含まれるかを確認する
        // 履歴にある場合 → 履歴エントリとして可視範囲に残す（固定位置に追加しない）
        // 履歴にない場合 → スクロール範囲外の固定位置に追加し、↑ キーで到達できるようにする
        let hiraganaInHistory = candidates.prefix(predictCount + historyCount).contains(hiragana)
        let katakanaInHistory = candidates.prefix(predictCount + historyCount).contains(katakana)

        var fixedCount = 0
        if !katakanaInHistory {
            candidates.removeAll { $0 == katakana }
            candidates.insert(katakana, at: 0)
            fixedCount += 1
        }
        // hiragana == katakana（非ひらがな文字）の場合は重複挿入しない
        if !hiraganaInHistory && hiragana != katakana {
            candidates.removeAll { $0 == hiragana }
            candidates.insert(hiragana, at: 0)
            fixedCount += 1
        }

        let historyEnd = fixedCount + predictCount + historyCount
        // 履歴・辞書候補がある場合はその先頭を初期選択、固定候補のみなら先頭から表示
        let initialRow = candidates.count > fixedCount ? fixedCount : 0
        guard !candidates.isEmpty else { return .dismiss }
        return .show(candidates: candidates, historyEnd: historyEnd, initialRow: initialRow)
    }
}
