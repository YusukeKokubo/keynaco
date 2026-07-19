---
status: superseded
created: 2026-05-28
superseded_by: PLAN260710-typing-feel-learning-gaps.md
references:
  - plans/PLAN260528b-history-phrase-recording.md
---

# PLAN260528: 履歴候補を文節単位で記録し、助詞付きフレーズのノイズを除去

**superseded（2026-07-19、PLAN260719 triage）**: 問題意識（助詞付きフレーズの履歴ノイズ）は [PLAN260710](PLAN260710-typing-feel-learning-gaps.md) に引き継がれた。助詞トリムの判定は D1（[PLAN260710a](PLAN260710a-particle-trim-lcid.md)、lcid 判定化・実装済み）、文節完成形の記録方針は D2 で検討中。本 plan の文字列ベースの設計はそちらで置き換え。

## 問題

変換確定時に「助詞付きフレーズ」が丸ごと履歴に記録され、短い読みで打ったときにノイズ候補として出てくる。

### ケース①: セグメントモードのフレーズ丸ごと記録

「きょうはいいてんきだ」をセグメントモードで確定すると、各文節に加えて合成フレーズ `(きょうはいいてんきだ, 今日はいい天気だ)` が 1 エントリ記録される（`doConfirmSegments` L.295-297）。次に「きょう」と打つと「今日はいい天気だ」が候補に出る。

### ケース②: 通常モードの助詞付き候補記録

「とうきょうが」と打って「東京が」を選択確定すると `(とうきょうが, 東京が)` が記録される。次に「とうきょう」と打つと前方一致で「東京が」が出る。

## 方針

### ① セグメントモードの fullReading 記録を削除

`InputHandler+SegmentMode.swift` の `doConfirmSegments` で `segments.count >= 2` のときに行っている合成フレーズ記録（L.295-297）を削除する。各文節の個別 `recordPrefixes` のみで十分。

```diff
-       if segmentState.segments.count >= 2 {
-           db.recordPrefixes(reading: fullReading, output: confirmed)
-       }
```

### ② 通常モードの末尾ひらがなトリム記録

`commitComposition` で候補確定時（L.227）、output の末尾のひらがな連続部分を除いた trimmed 版を記録する。reading も同様にトリム。trimmed == original の場合はそのまま記録。

```swift
// trimmed が original と異なる場合のみ trimmed を記録（元のフレーズは記録しない）
let trimmedOutput = Self.trimTrailingHiragana(selected)
let trimmedReading = Self.trimTrailingHiragana(normalizedInput)
if trimmedOutput.isEmpty || trimmedOutput == selected {
    db.recordPrefixes(reading: normalizedInput, output: selected)
} else {
    db.recordPrefixes(reading: trimmedReading, output: trimmedOutput)
}
```

`trimTrailingHiragana` は `DatabaseManager.isHiraganaPassthrough` の判定ロジック（`0x3041...0x3096`）を流用。

## トレードオフ

- 「きょうはいいてんきだ」と丸ごと打つフレーズ補完はできなくなる
- 「とうきょうが」→「東京が」を素早く出す用途がなくなる
- ユーザー評価: 圧倒的にノイズの方が多いので許容

## 実装対象ファイル

- `Core/Sources/Core/InputHandler+SegmentMode.swift`（①）
- `Core/Sources/Core/InputHandler.swift`（②）
- `Core/Sources/Core/InputHandler.swift` or `DatabaseManager+History.swift`（`trimTrailingHiragana` ヘルパー追加）

## テスト

- `ScenarioRegressionTests.swift` に「東京が」確定後「とうきょう」で候補確認するケースを追加
- セグメントモードの複数文節確定後、フル読みで候補が出ないことを確認
