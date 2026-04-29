import AppKit

// MARK: - 候補リスト構築・候補表示中・通常入力
//
// `handle()` の主要分岐 4 つ：
//   - handleCandidateVisible  : 候補ウィンドウ表示中のキー
//   - handleBracketModeKey    : 括弧候補ウィンドウ表示中のキー
//   - handleNormalInput       : 通常の文字入力（ローマ字・Shift・記号）
//   - buildCandidateList      : 候補列の組み立て（履歴・bi-gram・azooKey 統合）
//   - doConfirmSelection      : Enter による候補確定

extension InputHandler {

    // MARK: - 括弧候補マップ

    static let bracketOptions: [String: [String]] = [
        "[": ["「", "【", "〔", "［", "〈", "《", "『"],
        "]": ["」", "】", "〕", "］", "〉", "》", "』"],
        "(": ["（", "〔", "｟"],
        ")": ["）", "〕", "｠"],
        "{": ["｛"],
        "}": ["｝"],
    ]

    // MARK: - 括弧モード

    mutating func handleBracketModeKey(
        keyCode: UInt16,
        characters: String?,
        baseCharacters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        let brackets = bracketCandidates!
        let selectedText = candidate.selectedText ?? brackets[0]

        switch keyCode {
        case KeyCode.escape, KeyCode.backspace:
            bracketCandidates = nil
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0))
            return (true, .dismiss)

        case KeyCode.enter:
            bracketCandidates = nil
            client.insertText(selectedText)
            return (true, .dismiss)

        case KeyCode.tab where modifiers.contains(.shift), KeyCode.upArrow:
            return (true, .selectPrev)

        case KeyCode.space, KeyCode.tab, KeyCode.downArrow:
            return (true, .selectNext)

        default:
            // 選択中の括弧を確定して、このキーは通常処理へ
            bracketCandidates = nil
            client.insertText(selectedText)
            return handleNormalInput(keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                                      modifiers: modifiers, wasExplicitlySelected: false,
                                      candidate: .hidden, client: client)
        }
    }

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
            let row = candidate.selectedRow
            if candidate.fixedEnd <= row && row < candidate.historyEnd { return (true, .deleteSelected) }
            return (true, .none)
        default:
            if isBackspace { return doBackspace(client: client) }
            return nil
        }
    }

    // handleNormalInput は入力種別ごとのプライベートハンドラへ振り分けるディスパッチテーブル。
    // 各ハンドラは nil（自分の担当外）または (consumed, action) を返す。
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
                if state.isSegmentMode { applySegmentMarkedText(client: client) }
                else { applyMarkedText(candidateText: nil, client: client) }
                return (true, action)
            }
            return (false, .none)
        }

        if keyCode >= KeyCode.leftArrow && keyCode <= KeyCode.upArrow { return (false, .none) }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return (false, .none) }
        guard let chars = characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return (false, .none) }
        let base = baseCharacters ?? chars
        let isNonAscii = chars.unicodeScalars.contains(where: { $0.value >= 0x80 })

        if let r = handlePunctuation(base: base, modifiers: modifiers, client: client) { return r }
        if let r = handleBracketChar(chars: chars, client: client) { return r }
        if let r = handleShiftChar(chars: chars, isNonAscii: isNonAscii, modifiers: modifiers,
                                    wasExplicitlySelected: wasExplicitlySelected,
                                    candidate: candidate, client: client) { return r }
        if let r = handleNonAsciiChar(chars: chars, isNonAscii: isNonAscii, client: client) { return r }
        if let r = handleAsciiWord(chars: chars, wasExplicitlySelected: wasExplicitlySelected,
                                    candidate: candidate, client: client) { return r }
        return handleRomaji(base: base, wasExplicitlySelected: wasExplicitlySelected,
                             candidate: candidate, client: client)
    }

    /// - Parameter autoShow: 文字入力中の自動表示（true）か Space など明示トリガー（false）か。
    ///   autoShow=true のとき履歴も辞書候補もなければ表示しない。
    mutating func buildCandidateList(autoShow: Bool = false) -> CandidateAction {
        let h = state.composedHiragana
        let azooKeyCandidates = h.allSatisfy({ $0.isASCII }) ? [] : azooKeyConverter.requestCandidates(hiragana: h)
        let historyKey = (!h.isEmpty && h.allSatisfy({ $0.isASCII })) ? h.lowercased() : h
        let userDictExact = db.fetchUserDict(reading: historyKey)
        let userDictPrefix = db.fetchUserDictPrefix(reading: historyKey)
        let userDictRaw = userDictExact + userDictPrefix.filter { !userDictExact.contains($0) }
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

        if autoShow && historyCount == 0 && azooKeyCandidates.isEmpty && predictCount == 0
            && userDictRaw.isEmpty { return .dismiss }

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

        // ユーザー辞書エントリをカナ固定の直後（initialRow = fixedCount）に挿入する。
        // 予測・履歴より高優先で表示し、Shift+Delete の誤削除から守るため fixedEnd で追跡する。
        let uniqueUserDict = userDictRaw.filter { !candidates.contains($0) }
        candidates.insert(contentsOf: uniqueUserDict, at: fixedCount)
        let userDictCount = uniqueUserDict.count
        let fixedEnd = fixedCount + userDictCount

        let historyEnd = fixedEnd + predictCount + historyCount
        let predictionEnd = fixedEnd + predictCount
        // 履歴・辞書候補がある場合はその先頭を初期選択、固定候補のみなら先頭から表示
        let initialRow = candidates.count > fixedCount ? fixedCount : 0
        guard !candidates.isEmpty else { return .dismiss }
        return .show(candidates: candidates, historyEnd: historyEnd, initialRow: initialRow,
                     predictionEnd: predictionEnd, fixedEnd: fixedEnd)
    }

    /// composedHiragana が空で pendingRomaji が1文字のときに bi-gram を先読みして候補表示する。
    /// 候補が存在すれば isSuccessorMode = true を立てて返す。pendingRomaji は confirmSuccessor() で破棄される。
    mutating func buildPendingCandidateList(pendingChar: String, client: TextInputClient) -> CandidateAction {
        guard let kanas = InputHandler.romajiToInitialKana[pendingChar],
              let prev = lastCommittedOutput else { return .dismiss }
        var candidates: [String] = []
        for kana in kanas {
            let fromTrigram: [String] = prev2Output.map {
                db.fetchTrigram(prev2: $0, prev1: prev, reading: kana)
            } ?? []
            let fromBigram = db.fetchBigram(prev: prev, reading: kana)
            let fromSkip: [String] = mostRecentContentWord().map {
                db.fetchSkipBigram(prev: $0, reading: kana)
            } ?? []
            for s in fromTrigram where !candidates.contains(s) { candidates.append(s) }
            for s in fromBigram where !candidates.contains(s) { candidates.append(s) }
            for s in fromSkip where !candidates.contains(s) { candidates.append(s) }
        }
        guard !candidates.isEmpty else { return .dismiss }
        isSuccessorMode = true
        successorFirstChar = nil
        pendingSuccessorCandidates = []
        client.setMarkedText(candidates[0], selectionRange: NSRange(location: candidates[0].count, length: 0))
        let fixedCandidates = kanas
        let allCandidates = fixedCandidates + candidates.filter { !fixedCandidates.contains($0) }
        return .show(candidates: allCandidates, historyEnd: 0, initialRow: fixedCandidates.count, predictionEnd: 0, fixedEnd: 0)
    }

    // MARK: - Private input handlers

    private mutating func flushPendingRomaji() {
        guard !state.pendingRomaji.isEmpty else { return }
        state.composedHiragana += RomajiConverter.forceFinalize(state.pendingRomaji)
        state.pendingRomaji = ""
    }

    private mutating func handlePunctuation(
        base: String, modifiers: NSEvent.ModifierFlags, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        let punctuationMap: [String: String] = [",": "、", ".": "。"]
        guard let mappedPunct = punctuationMap[base], !modifiers.contains(.shift) else { return nil }
        if state.composingText.isEmpty {
            client.insertText(mappedPunct)
            return (true, .dismiss)
        }
        flushPendingRomaji()
        state.composedHiragana += mappedPunct
        let action = buildCandidateList()
        applyMarkedText(candidateText: nil, client: client)
        return (true, action)
    }

    private mutating func handleBracketChar(
        chars: String, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard let options = InputHandler.bracketOptions[chars] else { return nil }
        if state.composingText.isEmpty {
            bracketCandidates = options
            client.setMarkedText(options[0], selectionRange: NSRange(location: options[0].count, length: 0))
            return (true, .show(candidates: options, historyEnd: 0, initialRow: 0, predictionEnd: 0, fixedEnd: 0))
        }
        flushPendingRomaji()
        state.composedHiragana += options[0]
        let action = buildCandidateList()
        applyMarkedText(candidateText: nil, client: client)
        return (true, action)
    }

    private mutating func handleShiftChar(
        chars: String, isNonAscii: Bool, modifiers: NSEvent.ModifierFlags,
        wasExplicitlySelected: Bool, candidate: CandidateContext, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard modifiers.contains(.shift) && !isNonAscii else { return nil }
        if wasExplicitlySelected { _ = doConfirmSelection(candidate: candidate, client: client) }
        else { flushPendingRomaji() }
        state.composedHiragana += chars
        let action = buildCandidateList(autoShow: true)
        applyMarkedText(candidateText: nil, client: client)
        return (true, action)
    }

    private mutating func handleNonAsciiChar(
        chars: String, isNonAscii: Bool, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard isNonAscii else { return nil }
        if state.composingText.isEmpty {
            client.insertText(chars)
        } else {
            flushPendingRomaji()
            state.composedHiragana += chars
            applyMarkedText(candidateText: nil, client: client)
        }
        return (true, .dismiss)
    }

    private mutating func handleAsciiWord(
        chars: String, wasExplicitlySelected: Bool, candidate: CandidateContext, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction)? {
        guard !state.composedHiragana.isEmpty && state.pendingRomaji.isEmpty
              && state.composedHiragana.allSatisfy({ $0.isASCII }) else { return nil }
        if wasExplicitlySelected { _ = doConfirmSelection(candidate: candidate, client: client) }
        state.composedHiragana += chars
        let action = buildCandidateList(autoShow: true)
        applyMarkedText(candidateText: nil, client: client)
        return (true, action)
    }

    private mutating func handleRomaji(
        base: String, wasExplicitlySelected: Bool, candidate: CandidateContext, client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        if wasExplicitlySelected { _ = doConfirmSelection(candidate: candidate, client: client) }
        let needsRefresh = state.addRomaji(base)
        let hasBigramContext = lastCommittedOutput != nil && !state.composedHiragana.isEmpty
        let pending = state.pendingRomaji
        let hasPendingPreview = lastCommittedOutput != nil
            && state.composedHiragana.isEmpty
            && pending.count == 1
            && pending != "n"
            && InputHandler.romajiToInitialKana[pending] != nil

        let candidateAction: CandidateAction
        if needsRefresh || hasBigramContext {
            candidateAction = buildCandidateList(autoShow: true)
        } else if hasPendingPreview {
            candidateAction = buildPendingCandidateList(pendingChar: pending, client: client)
        } else {
            candidateAction = .dismiss
        }
        if !isSuccessorMode { applyMarkedText(candidateText: nil, client: client) }
        return (true, candidateAction)
    }
}
