# PLAN260429: IME 品質向上 3件

## 概要

docs/domain レビューで挙がった改善提案のうち、以下3件を実装する。

1. **ネガティブフィードバック学習** — 確定直後に Backspace で取り消した変換ペアを DB から弱める
2. **セグメント間 bigram 学習** — セグメントモード確定時に隣接セグメント間の bigram を記録する
3. **候補ウィンドウのセクションラベル** — 候補に「予測」「履歴」「辞書」の区分ラベルを表示する

---

## 1. ネガティブフィードバック学習

### 問題

確定後すぐ Backspace で消しても、その（reading, output）ペアは `history` / `bigram` に残り続ける。
同じ誤変換が何度も上位に出るが、手動で Shift+Delete するしかない。

### 実装方針

確定直後（`lastCommittedOutput` が更新された直後）に Backspace を検知したら `history` テーブルの
カウントを 1 だけ減らし、0 以下になればエントリを削除する。

**対象**: `history` テーブルのみ。`bigram` / `trigram` は時間減衰で自然に落ちるため不要。

### 変更箇所

#### `InputHandler.swift`

- `var lastConfirmedPair: (input: String, output: String)?` フィールドを追加
- `commitText(text:client:)` の `pushCommitted` 直前で
  `lastConfirmedPair = (state.finalizedText, text)` をセット
- `doBackspace()` に以下を追加（`state.backspace()` は既に `let (handled, needsRefresh)` で呼び出し済みのため、再呼び出しせず既計算の `handled` を使うこと）：
  ```swift
  let (handled, needsRefresh) = state.backspace()
  if !handled, let pair = lastConfirmedPair {
      db.penalizeHistory(input: pair.input, output: pair.output)
      lastConfirmedPair = nil
  }
  guard handled else { return (false, .none) }
  ```
- `handle(event:client:)` の先頭で Backspace 以外のキーなら `lastConfirmedPair = nil`
  （別キーを1打した時点でペナルティ機会を消す）

> **注意**: `commitText` は `doConfirmSegments` からも呼ばれる。セグメントモードでは
> `state.finalizedText` が fullReading になるため、セグメント確定後の Backspace にも
> 同じロジックが適用される（これは意図した動作）。

#### `DatabaseManager.swift`

```swift
func penalizeHistory(input: String, output: String) {
    execute { db in
        db.executeUpdate(
            "UPDATE history SET count = count - 1 WHERE input = ? AND output = ?",
            values: [input, output])
        db.executeUpdate(
            "DELETE FROM history WHERE input = ? AND output = ? AND count <= 0",
            values: [input, output])
    }
}
```

### テスト

`Tests/InputHandlerHistoryTests.swift` に追加:
- 確定後 Backspace → `db.fetchHistoryExact` でカウントが 1 減っていること
- count == 1 のエントリで Backspace → エントリが消えること
- 確定後に別キーを1打 → Backspace しても penalize されないこと

---

## 2. セグメント間 bigram 学習

### 問題

現在の `doConfirmSegments()` は：
- 各セグメントの `(reading, output)` を `recordPrefixes` で記録（unigram）
- 全体を `commitText(text: confirmed)` で記録（全体 bigram: 直前語 → フレーズ全体）

**記録されていないもの**: 隣接セグメント間の bigram。
例: `今日は良い天気です` を5セグメントで確定しても、`(今日, は)`, `(は, 良い)`,
`(良い, てんき, 天気)`, `(天気, で, です)` の bigram は記録されない。
次回「今日」を確定した後 Successor で「は」が出ない。

### 実装方針

`doConfirmSegments()` 内で全セグメントを確定した後、隣接ペアの bigram を記録する。
手動境界調整済みセグメントは強調学習（×3）する。

#### `Segment` 構造体に `isManuallyAdjusted: Bool` を追加

```swift
struct Segment {
    var reading: String
    var candidates: [String]
    var selectedIndex: Int
    var historyEnd: Int
    var isManuallyAdjusted: Bool = false  // 追加
}
```

`resizeFocusedSegment()` でリビルドされたセグメントに `isManuallyAdjusted = true` を付与：
```swift
var rebuilt = buildSegmentCandidates(reading: newFocusedReading, ...)
rebuilt.isManuallyAdjusted = true
segmentState.segments[i] = rebuilt
```

#### `doConfirmSegments()` に bigram 記録を追加

```swift
for seg in segmentState.segments {
    db.recordPrefixes(reading: seg.reading, output: seg.selectedText)
    azooKeyConverter.commit(reading: seg.reading, text: seg.selectedText)
    // 手動調整済みなら追加2回記録（計3回）
    if seg.isManuallyAdjusted {
        db.recordPrefixes(reading: seg.reading, output: seg.selectedText)
        db.recordPrefixes(reading: seg.reading, output: seg.selectedText)
    }
    confirmed += seg.selectedText
    fullReading += seg.reading
}
// 既存: フレーズ全体の prefix 記録（2セグメント以上）— 削除しないこと
if segmentState.segments.count >= 2 {
    db.recordPrefixes(reading: fullReading, output: confirmed)
}

// 追加: 隣接セグメント間の bigram を記録
let segs = segmentState.segments
for i in 0..<segs.count - 1 {
    let prev = segs[i].selectedText
    let next = segs[i + 1]
    db.recordBigram(prev: prev, input: next.reading, output: next.selectedText)
    if next.isManuallyAdjusted {
        db.recordBigram(prev: prev, input: next.reading, output: next.selectedText)
        db.recordBigram(prev: prev, input: next.reading, output: next.selectedText)
    }
}
```

> `recordBigram` は `INSERT OR REPLACE ... count = count + 1` の冪等実装なので、
> 同じペアを3回呼べば count が3増える。

### テスト

`Tests/InputHandlerSegmentTests.swift` に追加:
- 2セグメント確定後、`db.fetchBigram(prev: seg0.output, reading: seg1.reading)` に候補が含まれること
- 境界調整（Shift+→）後に確定 → bigram カウントが通常より大きいこと（3以上）

---

## 3. 候補ウィンドウのセクションラベル

### 問題

現状のウィンドウでは hiragana/katakana・予測・履歴・辞書の区別が視覚的にわかりにくい。
`history` 行（固定+予測+履歴）は一律 light blue 背景で、セパレータは履歴〜辞書間の1箇所のみ。
どれが削除可能で、どれが学習済みかがわからない。

### 現状の境界値

```
fixedRowCount  = fixedCount (= initialRow)            ← ひらがな/カタカナ行数
historySectionEnd                                       ← 固定+予測+履歴の末尾
```

足りない情報: `predictionSectionEnd = fixedCount + predictCount`（予測〜履歴の境界）

### 実装方針

各セクション最初の行の右端に小さいセクションラベルを表示する。
インデックスのずれを起こさないよう「ラベル行を挿入」ではなく「セル内にバッジ表示」で実装する。

#### `CandidateAction.show` に `predictionEnd` を追加

```swift
// Before
case show(candidates: [String], historyEnd: Int, initialRow: Int)
// After
case show(candidates: [String], historyEnd: Int, initialRow: Int, predictionEnd: Int)
```

`buildCandidateList()` で `predictionEnd = fixedCount + predictCount` を計算して渡す：
```swift
let predictionEnd = fixedCount + predictCount
return .show(candidates: candidates, historyEnd: historyEnd, initialRow: initialRow, predictionEnd: predictionEnd)
```

その他の `.show` 呼び出し（`buildPendingCandidateList`, セグメントモード, ブラケットモード等）は
`predictionEnd = historyEnd`（全体を一括扱い）でよい。

#### `CandidateWindow` に `predictionSectionEnd` プロパティを追加

```swift
private var predictionSectionEnd: Int = 0
```

`show()` の引数に `predictionEnd: Int = 0` を追加して受け取り・保存する。

#### `CandidateRowView` にセクションラベルを追加

```swift
let sectionLabel = NSTextField(labelWithString: "")
```

`sectionLabel`:
- フォントサイズ: 9pt
- 色: `NSColor.tertiaryLabelColor`
- 右端に配置（deleteButton の左側）

`tableView(_:viewFor:row:)` でラベルテキストを設定：
```swift
let sectionLabelText: String
switch row {
case fixedRowCount where row < predictionSectionEnd:     sectionLabelText = "予測"
case predictionSectionEnd where row < historySectionEnd: sectionLabelText = "履歴"
case historySectionEnd:                                   sectionLabelText = "辞書"
default:                                                  sectionLabelText = ""
}
rowView.sectionLabel.stringValue = sectionLabelText
```

既存の `sectionDivider` と `isHistory` の扱いも調整:
- `isHistory` ロジックを「固定行以外かつ historyEnd 未満」→「predictionEnd 以上かつ historyEnd 未満」に絞る
  （予測行を履歴行と同じ青背景にするのをやめる）
- `sectionDivider` はセクション境界（predictionEnd-1 行、historyEnd-1 行）の両方に表示

### 変更ファイル

| ファイル | 変更内容 |
|---------|---------|
| `InputHandler+Candidates.swift` | `CandidateAction.show` のシグネチャ変更、`predictionEnd` 計算・渡し |
| `CandidateWindow.swift` | `predictionSectionEnd` 追加、`show()` 引数追加、セル描画更新 |
| `InputController.swift` | `.show` を処理している箇所でシグネチャ変更に追従 |

### テスト

UI の自動テストは採用しない（方針通り）。
ビルド後に EventViewerWindow で実際の候補ウィンドウを目視確認する。

---

## 実装順序

1. **3（ラベル）** → 変更ファイルが明確で独立。視覚的な確認がしやすい。
2. **1（ペナルティ）** → `DatabaseManager` に1メソッド追加＋ `InputHandler` に数行。
3. **2（セグメント bigram）** → `Segment` 構造体変更を伴うため最後。

---

## 未決事項

- `CandidateAction.show` の associated value 追加はすべての pattern match を更新する必要がある。
  `if case .show` / `switch` パターンを全検索してから着手すること。特に `InputController.swift:148` の
  `case .show(let candidates, let historyEnd, let initialRow):` も更新必須。
- 辞書候補が0件のとき `historySectionEnd == candidates.count` になり「辞書」ラベル行が存在しない。
  この場合ラベルは表示されないが、辞書候補がなければ「辞書」ラベル不要なので許容範囲とする。
- `resizeFocusedSegment()` で `isManuallyAdjusted = true` を付与するターゲットを実装前に確認すること
  （expand/shrink 両方向、リビルドされる focused セグメントのみに付与）。
- セクションラベルを表示するか否かの設定項目は今回は設けない（常に表示）。
