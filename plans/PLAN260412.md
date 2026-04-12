# 変換セグメント分割・個別変換 実装計画

## Context

現状の Space キー変換は、入力全体（`composedHiragana`）をひとつの単位として候補リストを表示する。例えば「わたしはがくせい」と入力すると、"私は学生" のような複合候補がフラットなリストに並ぶ。

この機能では「ぶんせつ変換」を実装する: Space キーで辞書最長一致グリーディ法によって入力をセグメントに分割し（"わたし" / "は" / "がくせい"）、各セグメントを独立して変換・選択できるようにする。Left/Right でセグメント間を移動し、Enter で全確定。

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `Sources/DatabaseManager.swift` | `segmentize()` 追加、`fetchDict` を `internal` に昇格 |
| `Sources/CompositionState.swift` | `Segment` / `SegmentState` struct 追加、`segmentState` フィールド追加 |
| `Sources/TextInputClient.swift` | `setMarkedText(NSAttributedString)` をデフォルト実装付きで追加 |
| `Sources/InputController.swift` | `IMKTextInputAdapter` にNSAttributedString版を追加、`updateMarkedText` にセグメントモード対応を追加 |
| `Sources/InputHandler.swift` | `doEnterSegmentMode`, `handleSegmentModeKey`, `buildSegmentCandidates`, `doConfirmSegments`, `applySegmentMarkedText` 追加。Space キー処理・`commitComposition` の更新 |

---

## Step 1: `Sources/DatabaseManager.swift`

### 変更 A: `fetchDict` を `private` → `internal`

149行目:
```
private func fetchDict(reading: String) -> [String]
→
func fetchDict(reading: String) -> [String]
```

### 変更 B: `segmentize` メソッドを追加（`fetchCandidates` の後あたりに）

```swift
/// ひらがな文字列を辞書最長一致グリーディ法でセグメントに分割する。
/// 各セグメントの読みと辞書候補を返す。
func segmentize(_ hiragana: String) -> [(reading: String, candidates: [String])] {
    var result: [(reading: String, candidates: [String])] = []
    var remaining = hiragana
    let maxSegmentLen = 8  // 過度な長さのマッチを防ぐ上限

    while !remaining.isEmpty {
        var matched = false
        let tryLen = min(remaining.count, maxSegmentLen)
        for length in stride(from: tryLen, through: 2, by: -1) {
            let prefix = String(remaining.prefix(length))
            let candidates = fetchDict(reading: prefix)
            if !candidates.isEmpty {
                result.append((reading: prefix, candidates: candidates))
                remaining = String(remaining.dropFirst(length))
                matched = true
                break
            }
        }
        if !matched {
            // 辞書マッチなし → 1文字を1セグメント（助詞「は」「が」など）
            let single = String(remaining.removeFirst())
            result.append((reading: single, candidates: []))
        }
    }
    return result
}
```

---

## Step 2: `Sources/CompositionState.swift`

ファイル末尾（`CompositionState` struct の後）に追加:

```swift
// MARK: - セグメント変換

struct Segment {
    let reading: String
    var candidates: [String]   // [0]=ひらがな, [1]=カタカナ?, [2+]=辞書候補
    var selectedIndex: Int
    var historyEnd: Int        // CandidateWindow の historySectionEnd に渡す値

    var selectedText: String {
        guard !candidates.isEmpty else { return reading }
        return candidates[selectedIndex]
    }
}

struct SegmentState {
    var segments: [Segment]
    var focusedIndex: Int

    var focusedSegment: Segment {
        get { segments[focusedIndex] }
        set { segments[focusedIndex] = newValue }
    }

    var allSelectedText: String {
        segments.map(\.selectedText).joined()
    }
}
```

`CompositionState` struct 内に追加:

```swift
var segmentState: SegmentState? = nil
var isSegmentMode: Bool { segmentState != nil }
```

`reset()` を更新（segmentState もリセット）:

```swift
mutating func reset() -> Bool {
    guard !composingText.isEmpty || segmentState != nil else { return false }
    composedHiragana = ""
    pendingRomaji = ""
    segmentState = nil
    return true
}
```

---

## Step 3: `Sources/TextInputClient.swift`

プロトコルにデフォルト実装付きで追加:

```swift
extension TextInputClient {
    /// NSAttributedString 版（フォールバックは文字列版）
    func setMarkedText(_ text: NSAttributedString, selectionRange: NSRange) {
        setMarkedText(text.string, selectionRange: selectionRange)
    }
}
```

`MockTextClient` はデフォルト実装を使うため変更不要。

---

## Step 4: `Sources/InputController.swift`

### 変更 A: `IMKTextInputAdapter` に attributed 版を追加

```swift
func setMarkedText(_ text: NSAttributedString, selectionRange: NSRange) {
    client?.setMarkedText(text, selectionRange: selectionRange, replacementRange: .notFound)
}
```

### 変更 B: `updateMarkedText` をセグメントモード対応に更新

```swift
private func updateMarkedText(client: TextInputClient) {
    if let ss = handler.state.segmentState {
        // セグメントモード: 候補ウィンドウの選択中テキストを focused セグメントに反映
        let str = buildSegmentAttributedString(ss: ss, overrideFocusedText: candidateWindow.selectedText())
        client.setMarkedText(str, selectionRange: NSRange(location: str.length, length: 0))
    } else {
        let text: String
        if candidateWindow.isVisible, let selected = candidateWindow.selectedText() {
            text = selected + handler.state.pendingRomaji
        } else {
            text = handler.state.composingText
        }
        client.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0))
    }
}

/// セグメント全体の NSAttributedString を構築（focused=太い下線、他=細い下線）
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
```

---

## Step 5: `Sources/InputHandler.swift`（メイン変更）

### 変更 A: Space キー処理（122-129行目）

```swift
// 変更後
if keyCode == KeyCode.space {
    if !state.composedHiragana.isEmpty {
        let action = doEnterSegmentMode()  // ← doRefreshCandidates() から変更
        applyMarkedText(candidateText: nil, client: client)
        return (true, action)
    }
    return (false, .none)
}
```

### 変更 B: セグメントモードの最優先ハンドリング

`handle()` の `let wasExplicitlySelected = ...` の直後（61行目あたり）に追加:

```swift
if state.isSegmentMode {
    return handleSegmentModeKey(keyCode: keyCode, modifiers: modifiers, candidate: candidate, client: client)
}
```

### 変更 C: `commitComposition` のセグメントモード対応

```swift
mutating func commitComposition(client: TextInputClient, candidate: CandidateContext = .hidden) {
    // セグメントモード中の強制確定（アプリ切り替えなど）
    if let ss = state.segmentState {
        let selectedText = candidate.selectedText ?? ss.focusedSegment.selectedText
        var confirmed = ""
        for (i, seg) in ss.segments.enumerated() {
            let text = (i == ss.focusedIndex) ? selectedText : seg.selectedText
            db.record(input: seg.reading, output: text)
            confirmed += text
        }
        doCommit(text: confirmed, client: client)
        return
    }
    // 既存の処理（変更なし）
    guard !state.composingText.isEmpty else { return }
    ...
}
```

### 変更 D: 新規プライベートメソッド群

```swift
// MARK: - セグメントモード

private mutating func doEnterSegmentMode() -> CandidateAction {
    // pendingRomaji を確定してからセグメント化
    if !state.pendingRomaji.isEmpty {
        state.composedHiragana += RomajiConverter.forceFinalize(state.pendingRomaji)
        state.pendingRomaji = ""
    }
    let rawSegments = db.segmentize(state.composedHiragana)

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
    var candidates = dictCandidates
    var fixedCount = 0
    if !candidates.contains(katakana) {
        candidates.removeAll { $0 == katakana }
        candidates.insert(katakana, at: 0)
        fixedCount += 1
    }
    if !candidates.contains(hiragana) {
        candidates.removeAll { $0 == hiragana }
        candidates.insert(hiragana, at: 0)
        fixedCount += 1
    }
    // 辞書候補があれば先頭辞書候補を初期選択、なければひらがな
    let initialIndex = dictCandidates.isEmpty ? 0 : fixedCount
    return Segment(reading: reading, candidates: candidates, selectedIndex: initialIndex, historyEnd: fixedCount)
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
        guard ss.focusedIndex > 0 else { return (true, .none) }
        syncFocusedSegmentSelection(from: candidate)
        state.segmentState!.focusedIndex -= 1
        applySegmentMarkedText(client: client)
        return (true, makeCandidateActionForFocusedSegment())

    case KeyCode.rightArrow:
        guard ss.focusedIndex < ss.segments.count - 1 else { return (true, .none) }
        syncFocusedSegmentSelection(from: candidate)
        state.segmentState!.focusedIndex += 1
        applySegmentMarkedText(client: client)
        return (true, makeCandidateActionForFocusedSegment())

    case KeyCode.space, KeyCode.tab, KeyCode.downArrow:
        return (true, .selectNext)  // CandidateWindow + InputController.updateMarkedText に委譲

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
```

---

## Step 6: テスト追加

### `Tests/DatabaseManagerTests.swift`

```
testSegmentizeSingleSegment     — 辞書マッチが1つ → 1セグメント返す
testSegmentizeMultipleSegments  — "わたしはがくせい" → ["わたし","は","がくせい"] (要辞書登録)
testSegmentizeParticle          — 辞書にない1文字が1セグメントになる
```

### `Tests/InputHandlerTests.swift`

```
testSpaceEntersSegmentModeWhenMultipleSegments — 2+セグメントで Space → .show
testSpaceFallsBackToNormalModeForSingleSegment — 1セグメント → 従来の.show
testSegmentModeLeftRightMovesFocus             — Left/Right でフォーカスが移動する
testSegmentModeEnterConfirmsAllSegments        — Enter で全セグメント結合テキストが insertText される
testSegmentModeEscapeRestoresComposing         — Escape でセグメントモード解除・composedHiragana 維持
testSegmentModeBackspaceExits                  — Backspace でセグメントモード解除
testSegmentModeHistoryRecordedPerSegment       — 確定時に各セグメントが個別に db.record される
testCommitCompositionInSegmentMode             — deactivateServer 相当の強制確定が正しく動く
```

---

## 状態遷移

```
[composing]
    │ Space(2+セグ) → doEnterSegmentMode()
    ▼
[segment mode]
    ├─ ↑/↓/Space/Tab → .selectNext/.selectPrev (CandidateWindow + updateMarkedText が処理)
    ├─ Left → syncSelection + focusedIndex-- + applySegmentMarkedText + .show(新セグ候補)
    ├─ Right → syncSelection + focusedIndex++ + applySegmentMarkedText + .show(新セグ候補)
    ├─ Enter → doConfirmSegments → doCommit → [初期状態]
    ├─ Escape → segmentState = nil → [composing]
    └─ Backspace/他キー → segmentState = nil → [composing]
```

---

## 検証方法

1. ビルド＆インストール: `/deploy` スキルを実行
2. 手動テスト:
   - "わたしはがくせい" と入力 → Space
   - マークテキストが "私は学生" になり、"わたし" の候補ウィンドウが表示される
   - Right → "は" にフォーカス移動
   - Right → "がくせい" にフォーカス移動、"学生" が初期選択
   - ↓ で "学" "学生" etc. を切り替え
   - Enter → "私は学生" が確定
   - Escape でセグメントモードを解除し、ひらがなに戻ることを確認
3. ユニットテスト: `xcodebuild test -scheme ykey -destination "platform=macOS"`
