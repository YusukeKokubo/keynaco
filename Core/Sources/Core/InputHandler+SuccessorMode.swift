import AppKit

// MARK: - Successor モード
//
// 確定直後に「次に来そうな語」を自動表示するモード。
// noun-bigram の上位、必要なら格助詞 fallback を候補にする。

public extension InputHandler {

    mutating func clearSuccessorLLMAuxiliaryState() {
        successorLLMContext = nil
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

    /// 表層文字列を「助詞境界」で分割した prefix 候補列を返す（元の文字列は含めない）。
    nonisolated static func splitSurfaceAtParticles(_ surface: String) -> [String] {
        guard surface.count >= 2 else { return [] }
        let sortedParticles = particles.sorted { $0.count > $1.count }
        if sortedParticles.contains(where: { surface.hasPrefix($0) }) { return [] }
        var out: [String] = []
        var seen: Set<String> = []
        var idx = surface.startIndex
        while idx < surface.endIndex {
            var matchedParticle: String?
            var matchedLen = 0
            for p in sortedParticles {
                if surface[idx...].hasPrefix(p) { matchedParticle = p; matchedLen = p.count; break }
            }
            if matchedLen > 0, let p = matchedParticle {
                let afterIdx = surface.index(idx, offsetBy: matchedLen)
                if p == "で", afterIdx < surface.endIndex, surface[afterIdx...].hasPrefix("す") {
                    idx = surface.index(after: idx)
                    continue
                }
                let beforePrefix = String(surface[..<idx])
                if !beforePrefix.isEmpty, beforePrefix != surface, seen.insert(beforePrefix).inserted {
                    out.append(beforePrefix)
                }
                let withParticle = String(surface[..<afterIdx])
                if withParticle != surface, seen.insert(withParticle).inserted {
                    out.append(withParticle)
                }
                idx = afterIdx
            } else {
                idx = surface.index(after: idx)
            }
        }
        return out
    }

    /// 親フレーズ毎に最大 maxPerParent 個の prefix だけ採用し、元の親の直前に挿入する。
    /// 体言切り（助詞を含まない）を優先する。
    nonisolated static func expandSuccessorPrefixes(
        candidates: [String],
        maxPerParent: Int = 2,
        totalLimit: Int = LearningThresholds.successorMaxCandidates
    ) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        for c in candidates {
            let prefixes = splitSurfaceAtParticles(c)
            let nounEnd = prefixes.filter { p in !particles.contains(where: { p.hasSuffix($0) }) }
            let particleEnd = prefixes.filter { p in particles.contains(where: { p.hasSuffix($0) }) }
            var picked: [String] = []
            for p in nounEnd + particleEnd {
                if picked.count >= maxPerParent { break }
                if seen.contains(p) { continue }
                picked.append(p)
                seen.insert(p)
            }
            for p in picked { out.append(p) }
            if seen.insert(c).inserted { out.append(c) }
            if out.count >= totalLimit { break }
        }
        return Array(out.prefix(totalLimit))
    }

    /// 後続語候補を組み立ててモードに入る／出る判定をする。
    /// 候補がある場合は `pendingSuccessorCandidates` に保存して `.dismiss` を返す（1打目まで表示を遅延）。
    mutating func suggestSuccessors() -> CandidateAction {
        guard let last = lastCommittedOutput else {
            isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
            successorActiveCandidates = []; successorKanaPrefix = ""; successorRomajiBuffer = ""; successorSubsequentKeys = []
            clearSuccessorLLMAuxiliaryState()
            return .dismiss
        }
        guard isNounLike(last) else {
            isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
            successorActiveCandidates = []; successorKanaPrefix = ""; successorRomajiBuffer = ""; successorSubsequentKeys = []
            clearSuccessorLLMAuxiliaryState()
            return .dismiss
        }
        let predictTop = db.fetchNounBigramTop(prev: lastConfirmedNounOutput ?? last)
        // 名詞末尾のとき限定で格助詞 fallback を tail に追加
        let particlesFallback = isNounLike(last)
            ? InputHandler.particles.filter { !Set(predictTop).contains($0) }
            : []
        let candidates = predictTop + particlesFallback

        guard !candidates.isEmpty else {
            isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
            successorActiveCandidates = []; successorKanaPrefix = ""; successorRomajiBuffer = ""; successorSubsequentKeys = []
            clearSuccessorLLMAuxiliaryState()
            return .dismiss
        }

        successorLLMSurfaceExtras = []
        isSuccessorMode = true
        successorFirstChar = nil
        successorActiveCandidates = []; successorKanaPrefix = ""; successorRomajiBuffer = ""; successorSubsequentKeys = []
        let llmContext = Array(committedHistory.suffix(3))

        pendingSuccessorCandidates = candidates
        successorLLMContext = llmContext
        return .dismiss
    }

    mutating func confirmSuccessor(_ particle: String, client: TextInputClient) {
        isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
        successorActiveCandidates = []; successorKanaPrefix = ""; successorRomajiBuffer = ""; successorSubsequentKeys = []
        clearSuccessorLLMAuxiliaryState()
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
                successorActiveCandidates = []; successorKanaPrefix = ""; successorRomajiBuffer = ""; successorSubsequentKeys = []
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
                    fullReading: ctx.fullReading
                )
                lastConfirmedContext = nil
            }
            isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
            successorActiveCandidates = []; successorKanaPrefix = ""; successorRomajiBuffer = ""; successorSubsequentKeys = []
            clearSuccessorLLMAuxiliaryState()
            applyMarkedText(candidateText: nil, client: client)
            return (true, .dismiss)
        default:
            let first = successorFirstChar
            let capturedSubsequentKeys = successorSubsequentKeys
            if !pendingSuccessorCandidates.isEmpty, first == nil {
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
                    }
                    filtered = InputHandler.mergePendingSuccessorMatches(
                        dbOrdered: filtered, pending: pendingSuccessorCandidates, romajiKey: char
                    )
                    let particleMatches = (InputHandler.particleRomajiMap[char] ?? [])
                        .filter { pendingSuccessorCandidates.contains($0) }
                    var particleSeen = Set(filtered)
                    for p in particleMatches where particleSeen.insert(p).inserted {
                        filtered.append(p)
                    }
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
                        let expanded = InputHandler.expandSuccessorPrefixes(candidates: merged)
                        // 2打目以降の絞り込み用に active candidates とローマ字バッファを初期化
                        successorActiveCandidates = expanded
                        successorKanaPrefix = ""
                        successorRomajiBuffer = char
                        successorSubsequentKeys = []
                        return (true, .show(candidates: expanded, historyEnd: 0, initialRow: 0, predictionEnd: 0, fixedEnd: 0))
                    }
                }
            } else if first != nil, !successorActiveCandidates.isEmpty {
                // 2打目以降：accumulated romaji でかな prefix を更新し候補を絞り込む
                let char = (baseCharacters ?? characters ?? "").lowercased()
                if char.count == 1, let c = char.first, c.isLetter, c.isASCII {
                    let newRomaji = successorRomajiBuffer + char
                    let result = RomajiConverter.convert(newRomaji)
                    let newKanaPrefix = successorKanaPrefix + result.converted
                    let newRomajiBuffer = result.pending
                    let romajiIsValid = RomajiConverter.isValidRomajiPrefix(newRomajiBuffer)
                    if romajiIsValid {
                        if newKanaPrefix.isEmpty {
                            // まだかなが確定していない（子音積み中）→ 現在の候補を維持
                            successorRomajiBuffer = newRomajiBuffer
                            successorSubsequentKeys.append((keyCode: keyCode, characters: characters, baseCharacters: baseCharacters))
                            return (true, .show(candidates: successorActiveCandidates, historyEnd: 0, initialRow: 0, predictionEnd: 0, fixedEnd: 0))
                        }
                        if let last = lastCommittedOutput {
                            // かなが確定した → DB を reading prefix で再クエリして絞り込む
                            var seen = Set<String>()
                            var narrowed: [String] = []
                            let nounPrev = lastConfirmedNounOutput ?? last
                            let fromNoun = db.fetchNounBigram(prev: nounPrev, reading: newKanaPrefix)
                            for s in fromNoun where seen.insert(s).inserted { narrowed.append(s) }
                            // ひらがな/カタカナ出力の候補はテキストの前方一致でもフィルタ
                            for w in successorActiveCandidates where w.hasPrefix(newKanaPrefix) {
                                if seen.insert(w).inserted { narrowed.append(w) }
                            }
                            if !narrowed.isEmpty {
                                successorActiveCandidates = narrowed
                                successorKanaPrefix = newKanaPrefix
                                successorRomajiBuffer = newRomajiBuffer
                                successorSubsequentKeys.append((keyCode: keyCode, characters: characters, baseCharacters: baseCharacters))
                                return (true, .show(candidates: narrowed, historyEnd: 0, initialRow: 0, predictionEnd: 0, fixedEnd: 0))
                            }
                        }
                    }
                }
            }
            // モード解除、バッファがあれば先に通常入力に流す
            isSuccessorMode = false; successorFirstChar = nil; pendingSuccessorCandidates = []
            successorActiveCandidates = []; successorKanaPrefix = ""; successorRomajiBuffer = ""; successorSubsequentKeys = []
            clearSuccessorLLMAuxiliaryState()
            if let first {
                _ = handle(keyCode: first.keyCode, characters: first.characters, baseCharacters: first.baseCharacters,
                           modifiers: modifiers, candidate: .hidden, client: client)
            }
            for key in capturedSubsequentKeys {
                _ = handle(keyCode: key.keyCode, characters: key.characters, baseCharacters: key.baseCharacters,
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
