import AppKit

// MARK: - Successor モード
//
// 確定直後に「次に来そうな語」を自動表示するモード。
// noun-bigram の上位 + 履歴前方一致を候補にする。

public extension InputHandler {

    /// DB で得た候補の並びを保ち、`pending` からローマ字1文字に対応する読み前方一致の語を末尾に追加する（単体テスト可）。
    static func mergePendingSuccessorMatches(dbOrdered: [String], pending: [String], romajiKey: String) -> [String] {
        let key = romajiKey.lowercased()
        guard key.count == 1, let c = key.first, c.isLetter, c.isASCII,
              let kanas = romajiToInitialKana[String(c)], !kanas.isEmpty else {
            return dbOrdered
        }
        var seen = Set(dbOrdered)
        var out = dbOrdered
        for word in pending {
            guard kanas.contains(where: { word.hasPrefix($0) }) else { continue }
            if seen.insert(word).inserted { out.append(word) }
        }
        return out
    }

    /// 後続語候補を組み立ててモードに入る／出る判定をする。
    /// 候補がある場合は `pendingSuccessorCandidates` に保存して `.dismiss` を返す（1打目まで表示を遅延）。
    mutating func suggestSuccessors() -> CandidateAction {
        guard let last = lastCommittedOutput else {
            isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
            return .dismiss
        }
        guard isNounLike(last) else {
            isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
            return .dismiss
        }
        let nounBigrams = db.fetchNounBigramTop(prev: lastConfirmedNounOutput ?? last)

        isSuccessorMode = true
        successorFirstChar = nil
        pendingSuccessorCandidates = nounBigrams
        return .dismiss
    }

    mutating func confirmSuccessor(_ particle: String, client: TextInputClient) {
        isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
        state.pendingRomaji = ""
        db.recordPrefixes(reading: particle, output: particle)
        lastConfirmedContext = LastConfirmedContext(
            input: particle,
            output: particle,
            fullReading: nil
        )
        pushCommitted(particle)
        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0))
        client.insertText(particle)
    }

    mutating func handleSuccessorMode(
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
                isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
                applyMarkedText(candidateText: nil, client: client)
                return (true, .dismiss)
            }
            confirmSuccessor(selected, client: client)
            return (true, suggestSuccessors())
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
            isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
            applyMarkedText(candidateText: nil, client: client)
            return (true, .dismiss)
        default:
            let first = successorFirstChar
            if first == nil {
                let char = (baseCharacters ?? characters ?? "").lowercased()
                if char.count == 1, let c = char.first, c.isLetter, c.isASCII,
                   let last = lastCommittedOutput {
                    let kanas = InputHandler.romajiToInitialKana[char] ?? []
                    var filteredSeen = Set<String>()
                    var filtered: [String] = []
                    let nounPrev = lastConfirmedNounOutput ?? last
                    for kana in kanas {
                        let fromNoun = db.fetchNounBigram(prev: nounPrev, reading: kana)
                        for s in fromNoun where filteredSeen.insert(s).inserted { filtered.append(s) }
                        let fromHistory = db.fetchHistoryPrefix(reading: kana)
                        for s in fromHistory where filteredSeen.insert(s).inserted { filtered.append(s) }
                    }
                    filtered = InputHandler.mergePendingSuccessorMatches(
                        dbOrdered: filtered, pending: pendingSuccessorCandidates, romajiKey: char
                    )
                    if !filtered.isEmpty {
                        pendingSuccessorCandidates = []
                        successorFirstChar = (keyCode: keyCode, characters: characters, baseCharacters: baseCharacters)
                        let limited = Array(filtered.prefix(LearningThresholds.successorMaxCandidates))
                        return (true, .show(candidates: limited, historyEnd: 0, initialRow: 0, predictionEnd: 0, fixedEnd: 0))
                    }
                }
            }
            // モード解除、バッファがあれば先に通常入力に流す
            isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
            if let first {
                _ = handle(keyCode: first.keyCode, characters: first.characters, baseCharacters: first.baseCharacters,
                           modifiers: modifiers, candidate: .hidden, client: client)
            }
            return handle(keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                          modifiers: modifiers, candidate: .hidden, client: client)
        }
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
