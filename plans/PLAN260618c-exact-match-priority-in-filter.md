---
status: implemented
created: 2026-06-18
---

# PLAN260618c: 単セグメント完全一致候補を filterCandidatesForDisplay の先頭に引き上げる

## 背景

b6d848f（PLAN260618b）でセグメント対応フィルタを導入した結果、「かくにん → 角煮ん」問題は解消した。しかし「ないかくふ → 内閣府」が「内閣府令」「内閣府設置法」より後方に来る問題が残っている。

原因は `predictionFiltered` が「rubySum > inputLength でも末尾漢字なら通す」ルールで、予測補完の「内閣府令」（ruby=7 > 5）を完全一致の「内閣府」（ruby=5=5）と同列に通してしまうこと。フィルタ後のソートは lcid ランクのみで、完全一致かどうかは考慮されない。

## 方針

`filterCandidatesForDisplay` の返り値の中で、**単セグメント（data.count==1）かつ完全一致（rubySum==inputLength）** の候補をリスト先頭に引き上げ、それ以外を後ろに残す。

```
before: [内閣府令, 内閣府設置法, 内閣府, 内閣不信任案]
after:  [内閣府, 内閣府令, 内閣府設置法, 内閣不信任案]
```

### 実装箇所

`AzooKeyConverter.filterCandidatesForDisplay`（`Core/Sources/Core/AzooKeyConverter.swift`）の末尾に引き上げロジックを追加する。

```swift
static func filterCandidatesForDisplay(_ candidates: [Candidate], inputLength: Int) -> [Candidate] {
    // ... 既存の3段フィルタ ...
    let base = validCoverage.isEmpty ? predictionFiltered : validCoverage
    // 単セグメント完全一致を先頭に引き上げ
    let (exact, rest) = base.reduce(into: ([Candidate](), [Candidate]())) { acc, c in
        let rubySum = c.data.reduce(0) { $0 + $1.ruby.count }
        if c.data.count == 1 && rubySum == inputLength {
            acc.0.append(c)
        } else {
            acc.1.append(c)
        }
    }
    return exact + rest
}
```

`validCoverage.isEmpty ? predictionFiltered : validCoverage` の返り値変数名を `base` に変えてそのまま引き渡す形にする。各グループ内の相対順序は変えない（AzooKey スコア順を維持）。

## 注意点

- `endsWithKanji` + `isFunctionalKanaTail` など既存の各フィルタ段は一切変更しない
- フォールバック（`validCoverage.isEmpty ? predictionFiltered : validCoverage`）は維持する
- `exact` が空（例: 全候補が予測補完・マルチセグメント）の場合は `rest` がそのまま返るので挙動変化なし

## テスト

### ユニットテスト（正本）

`Core/Sources/CoreSlowTests/AzooKeyConverterTests.swift` に以下のケースを追加する。

```swift
// ないかくふ → 内閣府 が 内閣府令 より前に来る
func testNaikakufuExactMatchPrecedesCompletion() {
    let result = converter.requestCandidates(hiragana: "ないかくふ", leftSideContext: nil)
    let texts = result.texts
    guard let idxFu = texts.firstIndex(of: "内閣府"),
          let idxRei = texts.firstIndex(of: "内閣府令") else {
        return  // 両方なければスキップ
    }
    XCTAssertLessThan(idxFu, idxRei, "内閣府(完全一致) が 内閣府令(予測補完) より前に来ること")
}
```

### サンドボックス確認

```python
send({"reset": True})
send({"type_string": "naikakufu"})
send({"wait_azoo_key": {"timeoutMs": 3000}})
r = send({"key": "space", "fields": ["candidates", "fixedEnd", "historyEnd"]})
# 内閣府 が 内閣府令 より前にいること
assert r["candidates"].index("内閣府") < r["candidates"].index("内閣府令")
```

### 回帰確認

- `kakunin` → 確認 が依然 index 0-2 圏内にいること（角煮ん が出ないこと）
- `jissou` → 実装 が上位に出ること
