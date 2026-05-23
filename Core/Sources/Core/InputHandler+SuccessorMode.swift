import AppKit

// MARK: - Successor モード
//
// 組成なし・ASCII モードでない状態で通常キーを入力した瞬間、
// leftSideContext / lastCommittedOutput から prev を取り後続語候補を表示する。

public extension InputHandler {

    /// `leftSideContext` 末尾から漢字・カタカナのみの連続スパンを返す（例: `"今日は東京に"` → `"東京"`）。
    static func extractNounFromContext(_ context: String) -> String? {
        guard !context.isEmpty else { return nil }
        let chars = Array(context)
        var end = chars.count
        while end > 0 {
            let tail = String(chars[end - 1])
            if tail.unicodeScalars.last.map(isContentWordScalar) == true { break }
            end -= 1
        }
        guard end > 0 else { return nil }
        var start = end
        while start > 0 {
            let ch = String(chars[start - 1])
            guard ch.unicodeScalars.last.map(isContentWordScalar) == true else { break }
            start -= 1
        }
        return String(chars[start..<end])
    }

    private static func isContentWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        let isKanji = (v >= 0x4E00 && v <= 0x9FFF)
            || (v >= 0x3400 && v <= 0x4DBF)
            || (v >= 0xF900 && v <= 0xFAFF)
        let isKatakana = v >= 0x30A0 && v <= 0x30FF
        return isKanji || isKatakana
    }

    /// ローマ字1文字に対応する Successor 候補。候補なしなら nil（通常入力へ）。
    func trySuccessorCandidates(romajiChar: String) -> [String]? {
        let key = romajiChar.lowercased()
        guard key.count == 1, let c = key.first, c.isLetter, c.isASCII,
              let kanas = Self.romajiToInitialKana[key], !kanas.isEmpty else { return nil }
        let contextNoun = Self.extractNounFromContext(leftSideContext)
        let noun: String?
        if let contextNoun {
            noun = contextNoun
        } else if successorEligible {
            noun = lastCommittedOutput
        } else {
            return nil
        }
        guard let noun else { return nil }
        var seen = Set<String>()
        var result: [String] = []
        for kana in kanas {
            for s in db.fetchNounBigram(prev: noun, reading: kana)
                where seen.insert(s).inserted { result.append(s) }
            for s in db.fetchHistoryPrefix(reading: kana)
                where seen.insert(s).inserted { result.append(s) }
        }
        return result.isEmpty ? nil : Array(result.prefix(LearningThresholds.successorMaxCandidates))
    }

    /// Successor 候補ウィンドウ表示中のキー処理（`candidate.isVisible` && 組成空）。
    mutating func handleSuccessorCandidateKey(
        keyCode: UInt16,
        characters: String?,
        baseCharacters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        switch keyCode {
        case KeyCode.space, KeyCode.enter:
            guard let selected = candidate.selectedText else {
                successorBufferedRomaji = nil
                successorEligible = false
                state.pendingRomaji = ""
                applyMarkedText(candidateText: nil, client: client)
                return (true, .dismiss)
            }
            confirmSuccessor(selected, client: client)
            return (true, .dismiss)
        case KeyCode.downArrow, KeyCode.tab:
            return (true, .selectNext)
        case KeyCode.upArrow:
            return (true, .selectPrev)
        case KeyCode.escape, KeyCode.backspace, KeyCode.rightArrow:
            if keyCode == KeyCode.backspace, let ctx = lastConfirmedContext {
                db.penalizeAll(
                    input: ctx.input,
                    output: ctx.output,
                    fullReading: ctx.fullReading
                )
                lastConfirmedContext = nil
            }
            successorBufferedRomaji = nil
            successorEligible = false
            state.pendingRomaji = ""
            applyMarkedText(candidateText: nil, client: client)
            return (true, .dismiss)
        default:
            let buffered = successorBufferedRomaji
            successorBufferedRomaji = nil
            if let buffered {
                _ = state.addRomaji(buffered)
            }
            applyMarkedText(candidateText: nil, client: client)
            return handleNormalInput(
                keyCode: keyCode,
                characters: characters,
                baseCharacters: baseCharacters,
                modifiers: modifiers,
                wasExplicitlySelected: false,
                candidate: .hidden,
                client: client
            )
        }
    }

    mutating func confirmSuccessor(_ particle: String, client: TextInputClient) {
        successorBufferedRomaji = nil
        successorEligible = false
        state.pendingRomaji = ""
        db.recordPrefixes(reading: particle, output: particle)
        lastConfirmedContext = LastConfirmedContext(
            input: particle,
            output: particle,
            fullReading: nil
        )
        pushCommitted(particle)
        successorEligible = true
        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0))
        client.insertText(particle)
    }

    // MARK: - Successor 用の static データ

    /// ローマ字1文字 → 読みの先頭になりうるひらがな（N-gram 保留候補の読みフィルタに使用）
    static let romajiToInitialKana: [String: [String]] = [
        "a": ["あ"],
        "i": ["い"],
        "u": ["う"],
        "e": ["え"],
        "o": ["お"],
        "k": ["か", "き", "く", "け", "こ"],
        "s": ["さ", "し", "す", "せ", "そ"],
        "t": ["た", "ち", "つ", "て", "と"],
        "n": ["な", "に", "ぬ", "ね", "の"],
        "h": ["は", "ひ", "ふ", "へ", "ほ"],
        "m": ["ま", "み", "む", "め", "も"],
        "y": ["や", "ゆ", "よ"],
        "r": ["ら", "り", "る", "れ", "ろ"],
        "w": ["わ", "を", "う"],
        "g": ["が", "ぎ", "ぐ", "げ", "ご"],
        "z": ["ざ", "じ", "ず", "ぜ", "ぞ"],
        "d": ["だ", "ぢ", "づ", "で", "ど"],
        "b": ["ば", "び", "ぶ", "べ", "ぼ"],
        "p": ["ぱ", "ぴ", "ぷ", "ぺ", "ぽ"],
        "f": ["ふ"],
        "j": ["じ"],
        "c": ["か", "き", "く", "け", "こ", "ち"],
        "v": ["ヴ", "ゔ"],
    ]

    /// 漢字またはカタカナで終わる語（名詞らしい）かどうか
    func isNounLike(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        let v = last.value
        let isKanji = (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF) || (v >= 0xF900 && v <= 0xFAFF)
        let isKatakana = v >= 0x30A0 && v <= 0x30FF
        return isKanji || isKatakana
    }
}
