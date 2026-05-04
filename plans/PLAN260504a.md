# F1 同音異義語自動選択の精度向上

## 目的

「かみ → 紙/神/髪」「あい → 愛/AI/合い」のような同音異義語を、LLM が文脈から正しく選んで
候補リストの先頭に移動させる。ユーザーが ↑↓ で選び直す手間を減らし、理想的には
**Space → Enter の2打が Enter 1打**になるケースを増やす。

## 現状の課題

| 項目 | 現状 | 問題点 |
|------|------|--------|
| 文脈窓 | `surroundingText(maxLength: 100)` + `suffix(100)` で切り詰め | 二重に100文字制限がかかっており段落の話題を掴めない |
| F1 対象 | `lastF1Eligible = !autoShow`（Space 押下後のみ） | 文字入力中（autoShow）は候補先頭が不正確なまま表示される |
| few-shot | `bigramTop(prev: last, limit: 5)` | 1語前の統計のみ。2〜5語前の文脈は無視 |
| 確信度 | LLM は番号だけ返す | 誤判定でも強制的に候補を動かしてしまう |

## 改善案（4ステップ）

### Step 1: 文脈窓の拡大（変更コスト: 低）

現在は `maxLength: 100` の取得後に `suffix(100)` で再度切り詰めており、実質 **常に100文字**しか
LLM に渡らない。`maxLength` と切り詰め上限の両方を揃えて変更する。

```swift
// before
let rawPrefix = adapter.surroundingText(maxLength: 100).prefix
let contextPrefix = rawPrefix.count > 100 ? String(rawPrefix.suffix(100)) : String(rawPrefix)

// after
let rawPrefix = adapter.surroundingText(maxLength: 300).prefix
let contextPrefix = rawPrefix.count > 300 ? String(rawPrefix.suffix(300)) : String(rawPrefix)
```

300文字にするだけで「先週の会議で〜」「Xというプロジェクトは〜」のような
話題の軸が取れる。

### Step 2: committedHistory を文脈として補強（変更コスト: 低）

`surroundingText` は入力先アプリが提供するテキストなので、アプリによっては
空になる場合がある（Electron 系等）。`committedHistory.suffix(5)` を
フォールバック兼補足として追加する。

```swift
// InputController.applyCandidateF1Scheduling 内
let historyContext = handler.committedHistory.suffix(5).joined(separator: "")
let contextPrefix: String = {
    if rawPrefix.isEmpty { return historyContext }
    // rawPrefix に既に直近の確定語が含まれる場合に重複するが、
    // 多少の重複より「確実に文脈が入る」ことを優先する
    return "\(historyContext)\(rawPrefix)"
}()
```

surroundingText が取れているときも先頭に挿入して「直近の変換語」を LLM に明示する。
`rawPrefix` に直近語が既に含まれるケースでは文脈が重複するが、文脈が欠落するより安全。

### Step 3: 確信度フラグの導入（変更コスト: 中）

LLM の返答フォーマットを `番号` から `番号:high/mid/low` に変更し、
確信度が低い場合は候補を移動しない（ユーザー判断に委ねる）。

```
最も自然な候補の番号と確信度を「番号:high」「番号:mid」「番号:low」の形式で答えてください。
例: 2:high
```

`parseChosenIndex` を `parseChosenIndexWithConfidence` に拡張:

```swift
struct ScorerResult {
    let index: Int
    let confidence: Confidence
    enum Confidence { case high, mid, low }
}
```

確信度ごとの移動可否:

| 確信度 | autoShow 中 | Space 押下後（非 autoShow） |
|--------|------------|--------------------------|
| high   | 移動する   | 移動する                  |
| mid    | 移動しない | 移動する                  |
| low    | 移動しない | 移動しない（コールバック自体呼ばない） |

`onResult` は `low` の場合コールバックを呼ばない。`mid` は `wasAutoShow` フラグで分岐。

### Step 4: autoShow 時にも F1 を起動（変更コスト: 中、最大効果）

`InputHandler+Candidates.swift` の `lastF1Eligible = !autoShow` の `!autoShow` 条件を外す。
セグメント／Successor／括弧モードの guard は残す（それらの排除は `applyCandidateF1Scheduling`
側で行っており、`lastF1Eligible` は autoShow 判定だけを担っている）。

```swift
// before（実コードは複合条件）
lastF1Eligible = !autoShow
    && Self.isComposedHiraganaEligibleForF1(h)
    && !state.isSegmentMode
    && !isSuccessorMode
    && !isBracketMode
    && f1GlobalIndices.count >= 2

// after（!autoShow && のみ削除。残りはそのまま）
lastF1Eligible = Self.isComposedHiraganaEligibleForF1(h)
    && !state.isSegmentMode
    && !isSuccessorMode
    && !isBracketMode
    && f1GlobalIndices.count >= 2
```

autoShow 時（文字入力中の自動表示）でも F1 を起動すれば、
**読み入力が終わった時点で正解候補が先頭にある** = Space 不要で Enter 一打確定
というシナリオが現実的になる。

コールバック内の guard（Step 3 確信度と合わせて）:

```swift
// wasAutoShow はスコアリング起動時点でキャプチャしておく
guard result.confidence == .high || !wasAutoShow else { return }
guard result.index != 0 || !wasAutoShow else { return }  // autoShow で既に先頭なら再描画不要
```

**デバウンスについて**: autoShow では読みを1文字足すたびに `candidateScorer.cancel()` →
再スケジュールが走り、LLM タスクがほぼ完了前にキャンセルされ続ける。デバウンスは
現状の cancel 機構で自然に「最後の状態だけが LLM に届く」挙動に近いため、
まず実装してみて遅延・発熱に問題があれば追加検討する。

## ファイル変更範囲

| ファイル | 変更内容 |
|---------|---------|
| `LLMCandidateScorer.swift` | `buildPrompt` に確信度指示追加、`parseChosenIndex` → `parseChosenIndexWithConfidence`（`ScorerResult` 返却） |
| `InputController.swift` | `applyCandidateF1Scheduling`: `maxLength`+`suffix` を300に揃え、history 補強、`wasAutoShow` キャプチャ、確信度 guard |
| `InputHandler+Candidates.swift` | `lastF1Eligible` の **`!autoShow &&` のみ削除**（他条件は維持） |

テストは `LLMCandidateScorer` の `buildPrompt` / `parseChosenIndexWithConfidence` の
ユニットテストを追加（LLM 呼び出しはモック不要、static メソッドのみ）。
確信度パースの境界例（`2:high`、`2 : mid`、不正形式）を網羅すること。
**`2:unknown` → `nil`（パース失敗）**、**`2:low` → `ScorerResult` だが `score` 内で `onResult` 非呼び出し** と区別する。

`LLMCandidateScorer.swift` の変更と `LLMCandidateScorerTests.swift` の更新は**同一コミット**とする（`buildPrompt` 文言変更で既存アサーションが即失敗するため）。

## 実装順序

1. **Step 1**（文脈窓 100→300、`maxLength` と `suffix` 両方）: 変更コスト最小で即効果
2. **Step 2**（committedHistory 補強）: Step 1 と同時でも OK
3. **Step 3**（確信度）: Step 4 の前提、先に `LLMCandidateScorer` を改修（**当コミットにテスト更新を含める**）
4. **Step 4**（autoShow 対応）: Step 3 の確信度 guard があって初めて安全に入れる

## 期待効果

- 同音異義語（2字以上の読み）の変換精度が体感で改善
- autoShow 中に正解が先頭に来るケースが増え、**Space→Enter が Enter 一打**になる
- 確信度 low・mid（autoShow 時）のときは現状維持なのでリグレッションリスクが低い
