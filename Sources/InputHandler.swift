import AppKit

/// 候補ウィンドウに対する操作指示
enum CandidateAction {
    case none
    case show(candidates: [String], historyEnd: Int, initialRow: Int)
    case dismiss
    case selectNext
    case selectPrev
    case deleteSelected
}

/// 候補ウィンドウの現在状態スナップショット（読み取り専用）
struct CandidateContext {
    var isVisible: Bool
    var selectedRow: Int
    var selectedText: String?
    /// ユーザーが ↑↓ で明示的に候補を動かしたか（初期表示のまま = false）
    var isExplicitlySelected: Bool = false
    /// 履歴セクションの末尾インデックス（これ未満の行が履歴）
    var historyEnd: Int = 0

    static let hidden = CandidateContext(isVisible: false, selectedRow: 0, selectedText: nil)
}

private enum KeyCode {
    static let eisu:      UInt16 = 102
    static let kana:      UInt16 = 104
    static let backspace: UInt16 = 51
    static let space:     UInt16 = 49
    static let enter:     UInt16 = 36
    static let escape:    UInt16 = 53
    static let tab:       UInt16 = 48
    static let downArrow: UInt16 = 125
    static let upArrow:   UInt16 = 126
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
}

/// 入力処理の本体。IMK・UI に依存しない純粋なロジック。
struct InputHandler {

    // 全InputControllerインスタンスで共有するモード（アプリ切替後も保持）
    nonisolated(unsafe) static var isAsciiMode = false

    var state = CompositionState()
    var ignoreNextModeSwitch = false
    let db: DatabaseManager
    let azooKeyConverter: AzooKeyConverter

    init(db: DatabaseManager = .shared) {
        self.db = db
        self.azooKeyConverter = AzooKeyConverter()
    }

    // MARK: - 公開インターフェース

    mutating func handle(
        keyCode: UInt16,
        characters: String?,
        baseCharacters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {

        let wasExplicitlySelected = candidate.isVisible && candidate.isExplicitlySelected

        // セグメントモード中は最優先でハンドリング
        if state.isSegmentMode {
            return handleSegmentModeKey(keyCode: keyCode, modifiers: modifiers, candidate: candidate, client: client)
        }

        // 英数キー / かなキー
        if keyCode == KeyCode.eisu || keyCode == KeyCode.kana {
            if ignoreNextModeSwitch {
                ignoreNextModeSwitch = false
                return (true, .none)
            }
            if keyCode == KeyCode.eisu {
                if !state.composingText.isEmpty { commitComposition(client: client) }
                InputHandler.isAsciiMode = true
            } else {
                InputHandler.isAsciiMode = false
            }
            return (true, .none)
        }
        ignoreNextModeSwitch = false

        // 英字モード
        if InputHandler.isAsciiMode {
            if keyCode == KeyCode.escape { InputHandler.isAsciiMode = false; return (true, .none) }
            guard modifiers.intersection([.command, .control, .option]).isEmpty else { return (false, .none) }
            guard let chars = characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return (false, .none) }
            client.insertText(chars)
            return (true, .none)
        }

        let isBackspace = keyCode == KeyCode.backspace || characters == "\u{08}"

        // 候補ウィンドウ表示中
        if candidate.isVisible {
            switch keyCode {
            case KeyCode.tab where modifiers.contains(.shift):  // Shift+Tab
                return (true, .selectPrev)
            case KeyCode.space:   // Space → セグメントモードへ（または次の候補）
                if !state.composedHiragana.isEmpty {
                    let action = doEnterSegmentMode()
                    if state.isSegmentMode {
                        applySegmentMarkedText(client: client)
                    } else {
                        applyMarkedText(candidateText: nil, client: client)
                    }
                    return (true, action)
                }
                return (true, .selectNext)
            case KeyCode.tab, KeyCode.downArrow:  // Tab, ↓
                return (true, .selectNext)
            case KeyCode.upArrow:  // ↑
                return (true, .selectPrev)
            case KeyCode.enter:   // Return
                let action = doConfirmSelection(candidate: candidate, client: client)
                return (true, action)
            case KeyCode.escape:  // Escape
                return doEscape(client: client)
            case KeyCode.backspace where modifiers.contains(.shift):  // Shift+Delete: 履歴から削除
                if candidate.selectedRow < candidate.historyEnd {
                    return (true, .deleteSelected)
                }
                return (true, .none)
            default:
                if isBackspace { return doBackspace(client: client) }
            }
        } else {
            switch keyCode {
            case KeyCode.enter:   // Return
                guard !state.composingText.isEmpty else { return (false, .none) }
                commitComposition(client: client)
                return (true, .dismiss)
            case KeyCode.escape:  // Escape
                return doEscape(client: client)
            default:
                if isBackspace { return doBackspace(client: client) }
            }
        }

        // スペースキー（候補なし時）
        if keyCode == KeyCode.space {
            if !state.composedHiragana.isEmpty {
                let action = doEnterSegmentMode()
                if state.isSegmentMode {
                    applySegmentMarkedText(client: client)
                } else {
                    applyMarkedText(candidateText: nil, client: client)
                }
                return (true, action)
            }
            return (false, .none)
        }

        // 矢印キー等の特殊キー
        if keyCode >= KeyCode.leftArrow && keyCode <= KeyCode.upArrow { return (false, .none) }

        // 修飾キー付きはスルー
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return (false, .none) }

        // 印字可能文字のみ（ASCII および全角記号などの非ASCII文字を含む）
        guard let chars = characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return (false, .none) }
        let base = baseCharacters ?? chars

        // 句読点：かなモードで , → 、、. → 。に変換
        // 組成中なら組成バッファに追加して変換モードへ（候補ウィンドウを開く）
        // 組成なしなら直接挿入
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
                let action = doRefreshCandidates()
                applyMarkedText(candidateText: nil, client: client)
                return (true, action)
            }
        }

        let isNonAscii = chars.unicodeScalars.contains(where: { $0.value >= 0x80 })

        // Shift + ASCII → 組成バッファに英字として貯める（Enter で確定）
        if modifiers.contains(.shift) && !isNonAscii {
            if wasExplicitlySelected {
                _ = doConfirmSelection(candidate: candidate, client: client)
            } else if !state.pendingRomaji.isEmpty {
                state.composedHiragana += RomajiConverter.forceFinalize(state.pendingRomaji)
                state.pendingRomaji = ""
            }
            state.composedHiragana += chars
            applyMarkedText(candidateText: nil, client: client)
            return (true, .dismiss)
        }

        // 非ASCII文字（全角記号など）→ 組成中なら組成バッファに追加、空なら直接挿入
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

        if wasExplicitlySelected {
            _ = doConfirmSelection(candidate: candidate, client: client)
        }
        let needsRefresh = state.addRomaji(base)
        let candidateAction: CandidateAction = needsRefresh ? doRefreshCandidates(autoShow: true) : .dismiss
        applyMarkedText(candidateText: nil, client: client)
        return (true, candidateAction)
    }

    /// deactivateServer / commitComposition から呼ばれる未確定テキストの強制確定。
    /// candidate に明示的な選択（selectedRow > 0）がある場合はそちらを確定する。
    mutating func commitComposition(client: TextInputClient, candidate: CandidateContext = .hidden) {
        // セグメントモード中の強制確定（アプリ切り替えなど）
        if let ss = state.segmentState {
            let selectedText = candidate.selectedText ?? ss.focusedSegment.selectedText
            var confirmed = ""
            for (i, seg) in ss.segments.enumerated() {
                let text = (i == ss.focusedIndex) ? selectedText : seg.selectedText
                db.record(input: seg.reading, output: text)
                azooKeyConverter.commit(reading: seg.reading, text: text)
                confirmed += text
            }
            doCommit(text: confirmed, client: client)
            return
        }
        guard !state.composingText.isEmpty else { return }
        let inputKey = state.finalizedText
        if candidate.isVisible, let selected = candidate.selectedText {
            db.record(input: inputKey, output: selected)
            azooKeyConverter.commit(reading: inputKey, text: selected)
            doCommit(text: selected, client: client)
        } else {
            db.record(input: inputKey, output: inputKey)
            doCommit(text: inputKey, client: client)
        }
    }

    // MARK: - プライベートヘルパー

    @discardableResult
    private mutating func doConfirmSelection(candidate: CandidateContext, client: TextInputClient) -> CandidateAction {
        guard !state.composingText.isEmpty else { return .none }
        let inputKey = state.finalizedText
        // Enter キーによる確定: 視覚的に選択中の候補をそのまま確定する
        if let selected = candidate.selectedText {
            db.record(input: inputKey, output: selected)
            azooKeyConverter.commit(reading: inputKey, text: selected)
            doCommit(text: selected, client: client)
        } else {
            commitComposition(client: client)
        }
        return .dismiss
    }

    private mutating func doCommit(text: String, client: TextInputClient) {
        client.insertText(text)
        state = CompositionState()
    }

    /// - Parameter autoShow: 文字入力中の自動表示（true）か Space など明示トリガー（false）か。
    ///   autoShow=true のとき履歴候補がなければ表示しない（タイピング中の割り込みを抑制する）。
    private mutating func doRefreshCandidates(autoShow: Bool = false) -> CandidateAction {
        let azooKeyCandidates = azooKeyConverter.requestCandidates(hiragana: state.composedHiragana)
        let exactCandidates = db.fetchHistoryExact(reading: state.composedHiragana)
        let prefixCandidates = db.fetchHistoryPrefix(reading: state.composedHiragana)
        let historyCandidates = exactCandidates + prefixCandidates.filter { !exactCandidates.contains($0) }
        let historyCount = historyCandidates.count
        var candidates = historyCandidates + azooKeyCandidates.filter { !historyCandidates.contains($0) }

        if autoShow && historyCount == 0 { return .dismiss }

        let hiragana = state.composedHiragana
        let katakana = hiraganaToKatakana(hiragana)

        // 履歴にひらがな・カタカナが含まれるかを確認する
        // 履歴にある場合 → 履歴エントリとして可視範囲に残す（固定位置に追加しない）
        // 履歴にない場合 → スクロール範囲外の固定位置に追加し、↑ キーで到達できるようにする
        let hiraganaInHistory = candidates.prefix(historyCount).contains(hiragana)
        let katakanaInHistory = candidates.prefix(historyCount).contains(katakana)

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

        let historyEnd = fixedCount + historyCount
        // 履歴・辞書候補がある場合はその先頭を初期選択、固定候補のみなら先頭から表示
        let initialRow = candidates.count > fixedCount ? fixedCount : 0
        guard !candidates.isEmpty else { return .dismiss }
        return .show(candidates: candidates, historyEnd: historyEnd, initialRow: initialRow)
    }

    private func hiraganaToKatakana(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar in
            // ひらがな: U+3041〜U+3096 → カタカナ: U+30A1〜U+30F6 (offset +0x60)
            if scalar.value >= 0x3041 && scalar.value <= 0x3096 {
                return Character(UnicodeScalar(scalar.value + 0x60)!)
            }
            return Character(scalar)
        })
    }

    private func applyMarkedText(candidateText: String?, client: TextInputClient) {
        let text: String
        if let selected = candidateText {
            text = selected + state.pendingRomaji
        } else {
            text = state.composingText
        }
        client.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0))
    }

    private mutating func doBackspace(client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction) {
        let (handled, needsRefresh) = state.backspace()
        guard handled else { return (false, .none) }
        let action: CandidateAction = needsRefresh ? doRefreshCandidates() : .dismiss
        applyMarkedText(candidateText: nil, client: client)
        return (true, action)
    }

    private mutating func doEscape(client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction) {
        guard state.reset() else { return (false, .none) }
        applyMarkedText(candidateText: nil, client: client)
        return (true, .dismiss)
    }

    // MARK: - セグメントモード

    private mutating func doEnterSegmentMode() -> CandidateAction {
        if !state.pendingRomaji.isEmpty {
            state.composedHiragana += RomajiConverter.forceFinalize(state.pendingRomaji)
            state.pendingRomaji = ""
        }
        let rawSegments = azooKeyConverter.segmentize(state.composedHiragana)

        // 1セグメントのみなら従来の候補ウィンドウにフォールバック
        guard rawSegments.count >= 2 else {
            return doRefreshCandidates()
        }

        let segments = rawSegments.map { buildSegmentCandidates(reading: $0.reading, dictCandidates: $0.candidates) }
        state.segmentState = SegmentState(segments: segments, focusedIndex: 0)
        return makeCandidateActionForFocusedSegment()
    }

    private func buildSegmentCandidates(reading: String, dictCandidates: [String]) -> Segment {
        let hiragana = reading
        let katakana = hiraganaToKatakana(reading)
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

    private func makeCandidateActionForFocusedSegment() -> CandidateAction {
        guard let ss = state.segmentState else { return .none }
        let seg = ss.focusedSegment
        guard !seg.candidates.isEmpty else { return .dismiss }
        return .show(candidates: seg.candidates, historyEnd: seg.historyEnd, initialRow: seg.selectedIndex)
    }

    private mutating func handleSegmentModeKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        guard let ss = state.segmentState else { return (false, .none) }

        switch keyCode {
        case KeyCode.leftArrow:
            if modifiers.contains(.shift) {
                return resizeFocusedSegment(expand: false, candidate: candidate, client: client)
            }
            guard ss.focusedIndex > 0 else { return (true, .none) }
            syncFocusedSegmentSelection(from: candidate)
            state.segmentState!.focusedIndex -= 1
            applySegmentMarkedText(client: client)
            return (true, makeCandidateActionForFocusedSegment())

        case KeyCode.rightArrow:
            if modifiers.contains(.shift) {
                return resizeFocusedSegment(expand: true, candidate: candidate, client: client)
            }
            guard ss.focusedIndex < ss.segments.count - 1 else { return (true, .none) }
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
    private mutating func resizeFocusedSegment(
        expand: Bool,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        guard var ss = state.segmentState else { return (false, .none) }
        syncFocusedSegmentSelection(from: candidate)
        let i = ss.focusedIndex

        if expand {
            guard i + 1 < ss.segments.count else { return (true, .none) }
            let nextReading = ss.segments[i + 1].reading
            guard !nextReading.isEmpty else { return (true, .none) }
            let newFocusedReading = ss.segments[i].reading + String(nextReading.first!)
            let newNextReading = String(nextReading.dropFirst())
            ss.segments[i] = buildSegmentCandidates(
                reading: newFocusedReading,
                dictCandidates: azooKeyConverter.candidatesForSegment(reading:newFocusedReading)
            )
            if newNextReading.isEmpty {
                ss.segments.remove(at: i + 1)
            } else {
                ss.segments[i + 1] = buildSegmentCandidates(
                    reading: newNextReading,
                    dictCandidates: azooKeyConverter.candidatesForSegment(reading:newNextReading)
                )
            }
        } else {
            let focusedReading = ss.segments[i].reading
            guard focusedReading.count >= 2 else { return (true, .none) }
            let newFocusedReading = String(focusedReading.dropLast())
            let removedChar = String(focusedReading.last!)
            ss.segments[i] = buildSegmentCandidates(
                reading: newFocusedReading,
                dictCandidates: azooKeyConverter.candidatesForSegment(reading:newFocusedReading)
            )
            if i + 1 < ss.segments.count {
                let newNextReading = removedChar + ss.segments[i + 1].reading
                ss.segments[i + 1] = buildSegmentCandidates(
                    reading: newNextReading,
                    dictCandidates: azooKeyConverter.candidatesForSegment(reading:newNextReading)
                )
            } else {
                ss.segments.insert(
                    buildSegmentCandidates(
                        reading: removedChar,
                        dictCandidates: azooKeyConverter.candidatesForSegment(reading:removedChar)
                    ),
                    at: i + 1
                )
            }
        }

        state.segmentState = ss
        applySegmentMarkedText(client: client)
        return (true, makeCandidateActionForFocusedSegment())
    }

    private mutating func syncFocusedSegmentSelection(from candidate: CandidateContext) {
        guard let ss = state.segmentState, let selectedText = candidate.selectedText else { return }
        if let idx = ss.focusedSegment.candidates.firstIndex(of: selectedText) {
            state.segmentState!.segments[ss.focusedIndex].selectedIndex = idx
        }
    }

    private mutating func doConfirmSegments(candidate: CandidateContext, client: TextInputClient) -> CandidateAction {
        syncFocusedSegmentSelection(from: candidate)
        guard let ss = state.segmentState else { return .none }
        var confirmed = ""
        for seg in ss.segments {
            db.record(input: seg.reading, output: seg.selectedText)
            azooKeyConverter.commit(reading: seg.reading, text: seg.selectedText)
            confirmed += seg.selectedText
        }
        doCommit(text: confirmed, client: client)
        return .dismiss
    }

    private func applySegmentMarkedText(client: TextInputClient) {
        guard let ss = state.segmentState else { return }
        let str = buildSegmentAttributedString(ss: ss)
        client.setMarkedText(str, selectionRange: NSRange(location: str.length, length: 0))
    }

    private func buildSegmentAttributedString(ss: SegmentState, overrideFocusedText: String? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, seg) in ss.segments.enumerated() {
            let text = (i == ss.focusedIndex)
                ? (overrideFocusedText ?? seg.selectedText)
                : seg.selectedText
            let style: Int = (i == ss.focusedIndex)
                ? NSUnderlineStyle.thick.rawValue
                : NSUnderlineStyle.single.rawValue
            result.append(NSAttributedString(string: text, attributes: [.underlineStyle: style]))
        }
        return result
    }

}
