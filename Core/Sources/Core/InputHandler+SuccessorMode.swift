import AppKit

// MARK: - Successor モード
//
// 確定直後に「次に来そうな語」を自動表示するモード。
// bi-gram / tri-gram の上位、必要なら格助詞 fallback を候補にする。

public extension InputHandler {

    mutating func clearSuccessorLLMAuxiliaryState() {
        successorLLMTrigger = .none
        successorLLMBaseCandidates = nil
        successorLLMSurfaceExtras.removeAll()
    }

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
    /// N-gram 候補がある場合は `pendingSuccessorCandidates` に保存して `.dismiss` を返す（1打目まで表示を遅延）。
    /// 格助詞のみの場合（名詞末尾 + N-gram なし）は従来通り `.show` を返す。
    mutating func suggestSuccessors() -> CandidateAction {
        guard let last = lastCommittedOutput else {
            isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
            clearSuccessorLLMAuxiliaryState()
            return .dismiss
        }
        let bigramTop = db.fetchBigramTop(prev: last)
        let trigramTop: [String] = prev2Output.map { db.fetchTrigramTop(prev2: $0, prev1: last) } ?? []
        let skipBigramTop = mostRecentContentWords(n: 2)
            .map { db.fetchSkipBigramTop(prev: $0) }
            .reduce([]) { InputHandler.merged($0, $1) }
        let predictTop = InputHandler.merged(trigramTop, bigramTop, skipBigramTop)
        // 名詞末尾のとき限定で格助詞 fallback を tail に追加
        let particlesFallback = isNounLike(last)
            ? InputHandler.particles.filter { !Set(predictTop).contains($0) }
            : []
        let candidates = predictTop + particlesFallback

        guard !candidates.isEmpty else {
            isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
            clearSuccessorLLMAuxiliaryState()
            return .dismiss
        }

        successorLLMSurfaceExtras = []
        isSuccessorMode = true
        successorFirstChar = nil
        let llmContext = Array(committedHistory.suffix(3))

        if predictTop.isEmpty {
            // 格助詞 fallback のみ（N-gram なし）→ 従来通りすぐ表示
            pendingSuccessorCandidates = []
            successorLLMBaseCandidates = candidates
            successorLLMTrigger = .particlesOnly(context: llmContext)
            return .show(candidates: candidates, historyEnd: 0, initialRow: 0, predictionEnd: 0, fixedEnd: 0)
        } else {
            // 高信頼チェック：直近90日以内に閾値回数以上使ったペアは即時表示
            let topCount = db.fetchBigramTopCount(prev: last)
            if topCount >= InputHandler.successorImmediateThreshold {
                pendingSuccessorCandidates = []
                clearSuccessorLLMAuxiliaryState()
                return .show(candidates: candidates, historyEnd: 0, initialRow: 0, predictionEnd: 0, fixedEnd: 0)
            } else {
                // 通常 → 保存して1打目まで待つ
                pendingSuccessorCandidates = candidates
                successorLLMBaseCandidates = nil
                successorLLMTrigger = .pendingLowConfidence(context: llmContext)
                return .dismiss
            }
        }
    }

    mutating func confirmSuccessor(_ particle: String, client: TextInputClient) {
        isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
        clearSuccessorLLMAuxiliaryState()
        state.pendingRomaji = ""
        let capPrev1 = lastCommittedOutput
        let capPrev2 = prev2Output
        if let p1 = capPrev1 {
            db.recordBigram(prev: p1, input: particle, output: particle)
            if let p2 = capPrev2 {
                db.recordTrigram(prev2: p2, prev1: p1, input: particle, output: particle)
            }
        }
        db.recordPrefixes(reading: particle, output: particle)
        lastConfirmedContext = LastConfirmedContext(
            input: particle,
            output: particle,
            prev1: capPrev1,
            prev2: capPrev2,
            skipPrevs: [],
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
                clearSuccessorLLMAuxiliaryState()
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
                    prev1: ctx.prev1,
                    prev2: ctx.prev2,
                    skipPrevs: ctx.skipPrevs,
                    fullReading: ctx.fullReading
                )
                lastConfirmedContext = nil
            }
            isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
            clearSuccessorLLMAuxiliaryState()
            applyMarkedText(candidateText: nil, client: client)
            return (true, .dismiss)
        default:
            // 格助詞 fast-path: N-gram 保留なし かつ 名詞末尾のときのみ実行。
            // pendingSuccessorCandidates がある場合は N-gram フィルタを優先し fast-path をスキップ。
            let char = (baseCharacters ?? characters ?? "").lowercased()
            if pendingSuccessorCandidates.isEmpty,
               char.count == 1, let c = char.first, c.isLetter, c.isASCII,
               let last = lastCommittedOutput, isNounLike(last) {
                let matched = InputHandler.particleRomajiMap[char] ?? []
                if !matched.isEmpty {
                    successorFirstChar = (keyCode: keyCode, characters: characters, baseCharacters: baseCharacters)
                    let fromBigram = db.fetchBigramInList(prev: last, list: matched)
                    let fromTrigram: [String] = prev2Output.map {
                        db.fetchTrigramInList(prev2: $0, prev1: last, list: matched)
                    } ?? []
                    let ngram = InputHandler.merged(fromTrigram, fromBigram)
                    let ngramSet = Set(ngram)
                    let rest = matched.filter { !ngramSet.contains($0) }
                    return (true, .show(candidates: ngram + rest, historyEnd: 0, initialRow: 0, predictionEnd: 0, fixedEnd: 0))
                }
            }
            // fast-path 非該当かつ N-gram 保留あり → 1打目で読み前方一致フィルタして表示
            let first = successorFirstChar
            if !pendingSuccessorCandidates.isEmpty, first == nil {
                let char = (baseCharacters ?? characters ?? "").lowercased()
                if char.count == 1, let c = char.first, c.isLetter, c.isASCII,
                   let last = lastCommittedOutput {
                    let kanas = InputHandler.romajiToInitialKana[char] ?? []
                    var filteredSeen = Set<String>()
                    var filtered: [String] = []
                    for kana in kanas {
                        let fromTrigram: [String] = prev2Output.map {
                            db.fetchTrigram(prev2: $0, prev1: last, reading: kana)
                        } ?? []
                        let fromBigram = db.fetchBigram(prev: last, reading: kana)
                        let fromSkip = mostRecentContentWords(n: 2).flatMap {
                            db.fetchSkipBigram(prev: $0, reading: kana)
                        }
                        for s in fromTrigram where filteredSeen.insert(s).inserted { filtered.append(s) }
                        for s in fromBigram where filteredSeen.insert(s).inserted { filtered.append(s) }
                        for s in fromSkip where filteredSeen.insert(s).inserted { filtered.append(s) }
                    }
                    filtered = InputHandler.mergePendingSuccessorMatches(
                        dbOrdered: filtered, pending: pendingSuccessorCandidates, romajiKey: char
                    )
                    if !filtered.isEmpty {
                        var merged = filtered
                        var mergeSeen = Set(filtered)
                        for w in successorLLMSurfaceExtras where mergeSeen.insert(w).inserted {
                            merged.append(w)
                        }
                        pendingSuccessorCandidates = []
                        successorLLMSurfaceExtras = []
                        clearSuccessorLLMAuxiliaryState()
                        successorFirstChar = (keyCode: keyCode, characters: characters, baseCharacters: baseCharacters)
                        return (true, .show(candidates: merged, historyEnd: 0, initialRow: 0, predictionEnd: 0, fixedEnd: 0))
                    }
                }
                pendingSuccessorCandidates = []
            }
            // モード解除、バッファがあれば先に通常入力に流す
            isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
            clearSuccessorLLMAuxiliaryState()
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
