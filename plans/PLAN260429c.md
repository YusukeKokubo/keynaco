# PLAN260429c: E-1 Backspace 再変換（undo conversion）

## 目的

確定直後に Backspace を押すと、直前の確定テキストを読み（ひらがな）に戻し、
即座にセグメント変換モードへ入る。多くの IME が持つ「確定取り消し」相当の機能。

---

## 現状の Backspace 動作（変更前）

```
「東京都」確定（reading: "とうきょうと"）
→ Backspace:
    1. state.backspace() → handled=false（composingText が空）
    2. lastConfirmedPair が non-nil → db.penalizeHistory("とうきょうと", "東京都")
    3. return (false, .none) ← Backspace をアプリに素通し（"都" が削除される）
```

問題: ペナルティだけかかって文字も消える。読みは復元されない。

---

## 新しい Backspace 動作（変更後）

```
「東京都」確定（reading: "とうきょうと", output: "東京都"）
→ Backspace:
    1. state.backspace() → handled=false（composingText が空）
    2. lastConfirmedPair が non-nil:
        a. selectedRange() でカーソル位置を取得
        b. setMarkedText("とうきょうと", ..., replacementRange: (cursor - 3, length: 3))
           → アプリが "東京都" を削除し、マークドテキスト "とうきょうと" に置換
        c. state.composedHiragana = "とうきょうと"
        d. enterSegmentMode() → セグメント変換候補を表示
        e. lastConfirmedPair = nil
        f. return (true, candidateAction) ← Backspace を消費
```

---

## IMK の仕組み: replacementRange を使った再変換

macOS IMK の `setMarkedText(_:selectionRange:replacementRange:)` は
`replacementRange` を指定するとその範囲のテキストをマークドテキストで置換する。
これが標準的な再変換の手段。

```swift
// 「東京都」(3文字) を読み "とうきょうと" に戻す
let cursor = client.selectedRange().location  // カーソル直前
let outputLen = pair.output.utf16.count       // UTF-16 単位
client.setMarkedText(
    pair.input,
    selectionRange: NSRange(location: pair.input.count, length: 0),
    replacementRange: NSRange(location: cursor - outputLen, length: outputLen)
)
```

`selectedRange()` が `.notFound` を返す場合（一部アプリでサポート外）はフォールバック:
ペナルティのみかけて `(false, .none)` を返す（現在と同じ動作）。

---

## 変更対象ファイル

| ファイル | 変更内容 |
|---------|---------|
| `Sources/TextInputClient.swift` | `selectedRange()` と `setMarkedText(_:selectionRange:replacementRange:)` を追加 |
| `Sources/InputController.swift` | `IMKTextInputAdapter` に上記2メソッドを実装 |
| `Sources/InputHandler.swift` | `doBackspace()` に再変換ロジックを追加 |
| `Tests/MockTextClient.swift` | `selectedRange()` と replacementRange 版 `setMarkedText` を追加 |
| `Tests/InputHandlerBackspaceReconversionTests.swift` | 新規テストファイル |

---

## 詳細設計

### 1. `TextInputClient.swift`

```swift
protocol TextInputClient: AnyObject {
    func insertText(_ text: String)
    func setMarkedText(_ text: String, selectionRange: NSRange)
    func setMarkedText(_ text: NSAttributedString, selectionRange: NSRange)
    // ★ 追加
    func selectedRange() -> NSRange
    func setMarkedText(_ text: String, selectionRange: NSRange, replacementRange: NSRange)
    func cursorRect() -> NSRect
}

extension TextInputClient {
    func setMarkedText(_ text: NSAttributedString, selectionRange: NSRange) {
        setMarkedText(text.string, selectionRange: selectionRange)
    }
    // ★ デフォルト実装: replacementRange を無視して通常の setMarkedText に委譲
    // selectedRange が実装できない環境向けのフォールバック
    func setMarkedText(_ text: String, selectionRange: NSRange, replacementRange: NSRange) {
        setMarkedText(text, selectionRange: selectionRange)
    }
    // ★ NSRange.notFound は InputController.swift 内 private extension で定義されているため、
    //    ここでは NSRange(location: NSNotFound, length: 0) を使う
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
}
```

### 2. `InputController.swift` — `IMKTextInputAdapter`

```swift
func selectedRange() -> NSRange {
    return client?.selectedRange() ?? NSRange(location: NSNotFound, length: 0)
}

func setMarkedText(_ text: String, selectionRange: NSRange, replacementRange: NSRange) {
    client?.setMarkedText(text, selectionRange: selectionRange, replacementRange: replacementRange)
}
```

### 3. `InputHandler.swift` — `doBackspace()`

```swift
mutating func doBackspace(client: TextInputClient) -> (consumed: Bool, candidateAction: CandidateAction) {
    let (handled, needsRefresh) = state.backspace()

    if !handled, let pair = lastConfirmedPair {
        lastConfirmedPair = nil
        // 再変換を試みる
        let cursor = client.selectedRange()
        if cursor.location != NSNotFound && cursor.location >= pair.output.utf16.count {
            // アプリの確定テキストを読みで置換 → セグメントモードへ
            let outputLen = pair.output.utf16.count
            state.composedHiragana = pair.input
            let replRange = NSRange(location: cursor.location - outputLen, length: outputLen)
            let selRange = NSRange(location: pair.input.count, length: 0)
            client.setMarkedText(pair.input, selectionRange: selRange, replacementRange: replRange)
            let action = enterSegmentMode()
            if state.isSegmentMode {
                applySegmentMarkedText(client: client)
            } else {
                // 1セグメントのみで buildCandidateList フォールバックした場合
                applyMarkedText(candidateText: nil, client: client)
            }
            return (true, action)
        }
        // フォールバック: selectedRange 未サポートのアプリ → 従来動作
        db.penalizeHistory(input: pair.input, output: pair.output)
        return (false, .none)
    }

    guard handled else { return (false, .none) }
    let action: CandidateAction = needsRefresh ? buildCandidateList() : .dismiss
    applyMarkedText(candidateText: nil, client: client)
    return (true, action)
}
```

**ペナルティについて**: 再変換フロー（再変換 → 別候補選択）では、
既存の `recordPrefixes` / `recordBigram` の上書きが自然なペナルティ代わりになる。
明示的な `penalizeHistory` は不要（フォールバック時のみ維持）。

### 4. `MockTextClient.swift` への追加

```swift
var mockedSelectedRange: NSRange = .init(location: 0, length: 0)
var lastReplacementRange: NSRange? = nil

func selectedRange() -> NSRange { mockedSelectedRange }

func setMarkedText(_ text: String, selectionRange: NSRange, replacementRange: NSRange) {
    lastReplacementRange = replacementRange
    // テスト用: mockedSelectedRange を更新してカーソルが text.count 移動したとみなす
    mockedSelectedRange = NSRange(location: text.count, length: 0)
    setMarkedText(text, selectionRange: selectionRange)
}
```

---

## テストシナリオ

### 基本再変換

```swift
// 「東京都」(3文字) 確定後に Backspace
// commitText は lastConfirmedPair = (state.finalizedText, text) とセットするため、
// 読みを事前に composedHiragana にセットしておく必要がある
handler.state.composedHiragana = "とうきょうと"
handler.commitText(text: "東京都", client: client)  // lastConfirmedPair = ("とうきょうと", "東京都")
client.mockedSelectedRange = NSRange(location: 3, length: 0)

let (consumed, action) = handler.doBackspace(client: client)

XCTAssertTrue(consumed)
// state がセグメントモードに入っている（2セグメント以上ある場合）
XCTAssertTrue(handler.state.isSegmentMode)
// replacementRange が正しく計算された
XCTAssertEqual(client.lastReplacementRange, NSRange(location: 0, length: 3))
// lastConfirmedPair はクリアされた
XCTAssertNil(handler.lastConfirmedPair)
```

### フォールバック（selectedRange が .notFound）

```swift
client.mockedSelectedRange = .notFound

let (consumed, _) = handler.doBackspace(client: client)

XCTAssertFalse(consumed)  // アプリに Backspace を素通し
XCTAssertNil(handler.lastConfirmedPair)
// ペナルティが記録された
// ... db.penalizeHistory が呼ばれたことを検証
```

### カーソル位置が output より手前（カーソル移動後）

```swift
// 「東京都」確定後、ユーザーが左矢印2回でカーソルを移動した場合
client.mockedSelectedRange = NSRange(location: 1, length: 0)  // 3文字の output に足りない

let (consumed, _) = handler.doBackspace(client: client)

XCTAssertFalse(consumed)  // 安全にフォールバック
```

### 2回目の Backspace は再変換しない

```swift
// 再変換後 lastConfirmedPair は nil → 通常の組成 Backspace として処理
let (_, _) = handler.doBackspace(client: client)  // 1回目: 再変換
let (consumed2, _) = handler.doBackspace(client: client)  // 2回目: セグメントモード内の Backspace
// セグメントモード中なら handleSegmentModeKey に流れる（doBackspace は呼ばれない）
```

### キー入力後は再変換しない（lastConfirmedPair がクリア済み）

```swift
// handle() の先頭で !isBackspace の場合に lastConfirmedPair を nil にしている（既存動作）
// よって「東京都」確定 → 別キー → Backspace では再変換は発動しない
```

---

## 実装順序

| 順 | 作業 | ファイル | 規模 |
|----|------|---------|------|
| 1 | `TextInputClient` にメソッド追加（デフォルト実装付き） | `TextInputClient.swift` | 10行 |
| 2 | `IMKTextInputAdapter` に実装 | `InputController.swift` | 10行 |
| 3 | `MockTextClient` に `selectedRange` / replacementRange 版追加 | `Tests/MockTextClient.swift` | 15行 |
| 4 | `doBackspace()` を改修 | `InputHandler.swift` | 20行 |
| 5 | テスト追加 | `Tests/InputHandlerBackspaceReconversionTests.swift` | — |
| 6 | ドキュメント更新 | `docs/domain/states.md`, `CLAUDE.md` | — |

既存のテストへの影響: `doBackspace` のシグネチャは変わらないが内部挙動が変わる。
既存テストで `mockedSelectedRange` を設定していない場合はデフォルト `.init(location: 0, length: 0)` になり、
`cursor.location (0) < pair.output.utf16.count` で必ずフォールバックする。
既存テストの期待値が変わる場合は `mockedSelectedRange` を適切に設定する。

---

## リスクと制限

| リスク | 対策 |
|-------|------|
| `selectedRange()` が `.notFound` を返すアプリ（一部 Electron, ターミナル等） | フォールバック: ペナルティのみかけて素通し |
| カーソルが確定後に移動している（矢印キー等） | `cursor.location < outputLen` でガード → フォールバック |
| `output` が空文字（理論上なし） | `outputLen == 0` で分岐が起きないよう `output.isEmpty` ガードを追加可 |
| セグメントが1つしか得られない場合 | `enterSegmentMode()` が `buildCandidateList()` にフォールバックする（既存動作） |
| `setMarkedText(replacementRange:)` を IMKTextInput がサポートしない古い API | macOS IMK は長年サポート。デフォルト実装でフォールバック済み |

---

## 対象外（今回スコープ外）

- **IDEA260327 A-3 訂正シグナル**との統合（別イシュー）
- Successor モード中の Backspace 再変換（現在 Successor モード中の Backspace は `handleSuccessorMode` が先に処理するため別途検討が必要）
- セグメントモード中の Backspace 再変換（セグメントモード中は `handleSegmentModeKey` が先に処理）
