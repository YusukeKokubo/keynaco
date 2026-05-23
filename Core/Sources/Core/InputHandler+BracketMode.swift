import AppKit

public extension InputHandler {

    // MARK: - z + キー 特殊文字マップ

    static let zCharMap: [String: String] = [
        "-": "〜", "/": "・", ".": "…", ",": "、",
    ]
    static let zArrowMap: [UInt16: String] = [
        KeyCode.rightArrow: "→", KeyCode.leftArrow: "←",
    ]

    // MARK: - 括弧候補マップ

    static let bracketOptions: [String: [String]] = [
        "[": ["「", "【", "〔", "［", "〈", "《", "『"],
        "]": ["」", "】", "〕", "］", "〉", "》", "』"],
        "(": ["（", "〔", "｟"],
        ")": ["）", "〕", "｠"],
        "{": ["｛"],
        "}": ["｝"],
        "?": ["？", "?"],
        "!": ["！", "!"],
        "/": ["・", "／", "/"],
        ".": ["。", "．", "…", "‥", "・", "."],
        ",": ["、", "'", "•", ",", "○", ".", "…", "‥", "·"],
        "@": ["＠", "@"],
        "#": ["＃", "#"],
        "$": ["＄", "$"],
        "%": ["％", "%"],
        "^": ["＾", "^"],
        "&": ["＆", "&"],
        "*": ["＊", "*"],
        "<": ["＜", "<"],
        ">": ["＞", ">"],
        "_": ["＿", "_"],
        "+": ["＋", "±", "+"],
        "|": ["｜", "|"],
        ":": ["：", "；", ";", ":"],
        "\"": ["\u{201C}", "\u{201D}", "＂", "\""],
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
            let isDateTime = Self.generateDateTimeCandidates(for: normalizedInput).contains(selected)
            let isNumber = Self.generateNumberCandidates(for: normalizedInput).contains(selected)
            if !isDateTime && !isNumber {
                db.recordPrefixes(reading: normalizedInput, output: selected)
                // 4文字以上の日本語読みのみセグメント分割して部分語を学習
                if !normalizedInput.allSatisfy({ $0.isASCII }),
                   normalizedInput.count >= Self.segmentizeMinReadingLength {
                    let db = db; let conv = azooKeyConverter; let reading = normalizedInput
                    let leftCtx = azooKeyLeftContext
                    Task.detached(priority: .utility) {
                        let segs = conv.segmentize(reading, leftSideContext: leftCtx)
                        guard segs.count >= 2 else { return }
                        for seg in segs {
                            guard let output = seg.candidates.first else { continue }
                            // 出力が読みと同じ（漢字化されていない）セグメントは学習価値なしのためスキップ
                            if output == seg.reading { continue }
                            db.recordPrefixes(reading: seg.reading, output: output)
                        }
                    }
                }
            }
            let conv = azooKeyConverter; let r = inputKey; let t = selected
            Task.detached(priority: .utility) { conv.commit(reading: r, text: t) }
            commitText(text: selected, skipHistory: isDateTime || isNumber, client: client)
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
            // 候補選択中（↑↓操作済み）は再変換せず次候補へ
            if !candidate.isExplicitlySelected, !state.composedHiragana.isEmpty {
                let action = enterSegmentMode()
                if state.isSegmentMode {
                    applySegmentMarkedText(client: client)
                    return (true, action)
                } else {
                    applyMarkedText(candidateText: nil, client: client)
                    if case .show(let candidates, let historyEnd, _, _, _) = action {
                        // ひらがな優先語は辞書候補の有無によらず initialRow を維持
                        if isHiraganaPreferred(state.composedHiragana) || candidates.count > historyEnd {
                            return (true, action)
                        }
                    }
                }
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
}
