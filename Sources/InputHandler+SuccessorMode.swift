import AppKit

// MARK: - Successor モード
//
// 確定直後に「次に来そうな語」を自動表示するモード。
// bi-gram / tri-gram の上位、必要なら格助詞 fallback を候補にする。

extension InputHandler {

    /// 後続語候補を組み立ててモードに入る／出る判定をする。
    /// - Returns: 候補があれば `.show`、無ければ `.dismiss`。
    mutating func suggestSuccessors() -> CandidateAction {
        guard let last = lastCommittedOutput else {
            isSuccessorMode = false; successorFirstChar = nil
            return .dismiss
        }
        let bigramTop = db.fetchBigramTop(prev: last)
        let trigramTop: [String] = prev2Output.map { db.fetchTrigramTop(prev2: $0, prev1: last) } ?? []
        let predictTop = trigramTop + bigramTop.filter { !trigramTop.contains($0) }
        // 名詞末尾のとき限定で格助詞 fallback を tail に追加
        let particlesFallback = isNounLike(last)
            ? InputHandler.particles.filter { !predictTop.contains($0) }
            : []
        let candidates = predictTop + particlesFallback

        guard !candidates.isEmpty else {
            isSuccessorMode = false; successorFirstChar = nil
            return .dismiss
        }

        isSuccessorMode = true
        successorFirstChar = nil
        return .show(candidates: candidates, historyEnd: 0, initialRow: 0)
    }

    mutating func confirmSuccessor(_ particle: String, client: TextInputClient) {
        isSuccessorMode = false; successorFirstChar = nil
        if let p1 = lastCommittedOutput {
            db.recordBigram(prev: p1, input: particle, output: particle)
            if let p2 = prev2Output {
                db.recordTrigram(prev2: p2, prev1: p1, input: particle, output: particle)
            }
        }
        db.record(input: particle, output: particle)
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
                isSuccessorMode = false; successorFirstChar = nil
                client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0))
                return (true, .dismiss)
            }
            confirmSuccessor(selected, client: client)
            return (true, suggestSuccessors())
        case KeyCode.downArrow, KeyCode.tab:
            return (true, .selectNext)
        case KeyCode.upArrow:
            return (true, .selectPrev)
        case KeyCode.escape, KeyCode.backspace, KeyCode.rightArrow:
            isSuccessorMode = false; successorFirstChar = nil
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0))
            return (true, .dismiss)
        default:
            // 格助詞 fast-path: 名詞末尾の確定後は候補に格助詞 fallback が必ず含まれる。
            // このときはローマ字 1 打で「が/を/に…」に絞り込める既存挙動を維持する。
            let char = (baseCharacters ?? characters ?? "").lowercased()
            if char.count == 1, let c = char.first, c.isLetter, c.isASCII,
               let last = lastCommittedOutput, isNounLike(last) {
                let matched = InputHandler.particleRomajiMap[char] ?? []
                if !matched.isEmpty {
                    successorFirstChar = (keyCode: keyCode, characters: characters, baseCharacters: baseCharacters)
                    let fromBigram = db.fetchBigramInList(prev: last, list: matched)
                    let fromTrigram: [String] = prev2Output.map {
                        db.fetchTrigramInList(prev2: $0, prev1: last, list: matched)
                    } ?? []
                    let merged = fromTrigram + fromBigram.filter { !fromTrigram.contains($0) }
                    let rest = matched.filter { !merged.contains($0) }
                    return (true, .show(candidates: merged + rest, historyEnd: 0, initialRow: 0))
                }
            }
            // fast-path 非該当 → モード解除、バッファがあれば先に通常入力に流す
            let first = successorFirstChar
            isSuccessorMode = false; successorFirstChar = nil
            if let first {
                _ = handle(keyCode: first.keyCode, characters: first.characters, baseCharacters: first.baseCharacters,
                           modifiers: modifiers, candidate: .hidden, client: client)
            }
            return handle(keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                          modifiers: modifiers, candidate: .hidden, client: client)
        }
    }

    // MARK: - Successor 用の static データ

    /// 頭文字（ローマ字1文字）→ 格助詞リスト（複数ある場合は使用頻度の高い順）
    static let particleRomajiMap: [String: [String]] = [
        "g": ["が"],
        "w": ["を"],
        "n": ["に", "の"],
        "d": ["で"],
        "h": ["は", "へ"],
        "t": ["と"],
        "k": ["から"],
        "m": ["も", "まで"],
        "y": ["より"],
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
