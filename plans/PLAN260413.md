# セグメント分割の改善: DP + 履歴スコアリング

## 背景

現在の `segmentize` は**貪欲最長一致（greedy longest-match）**で実装されている。
左から順に辞書に引っかかる最長の文字列を取り続けるため、局所最適な選択が後続の分割を悪化させるケースがある。

### Greedy が失敗する例

```
入力: "はなみずき"
辞書: "はな"(花), "はなみ"(花見), "みずき"(水木)

Greedy: "はなみ"(3) → "ず"(1) + "き"(1)   ← 辞書カバレッジ = 3文字
DP最適: "はな"(2) + "みずき"(3)            ← 辞書カバレッジ = 5文字（全マッチ）
```

### 履歴を活用する動機

`history` テーブルには確定済みの `(input, output, count)` が蓄積されている。
例えば「とうきょうタワー」と入力して "タワー" を1セグメントとして手動で確定すると
`record(input: "タワー", output: "タワー")` が呼ばれ、履歴に残る。

この情報を `segmentize` に渡せば:
- **辞書にない固有名詞・略語**でも、一度確定すれば次回から正しく切れる
- ユーザーの語彙・分割パターンに合わせてIMEが育っていく

---

## 設計

### スコアリング関数

各セグメント候補 `(reading, len)` に対してスコアを算出:

```
dictScore  = len  （辞書にある場合）/ 0（ない場合）
histScore  = min(histCount, 4)  （履歴の使用回数、上限4）
totalScore = dictScore + histScore
```

セグメントとして考慮する条件: `totalScore > 0`（辞書 or 履歴のどちらかにある）

| パターン | dictScore | histScore | 結果 |
|---|---|---|---|
| 辞書あり + 履歴多用 | len | 4 | 最優先 |
| 辞書あり + 履歴なし | len | 0 | 通常 |
| 辞書なし + 履歴あり | 0 | 1〜4 | 固有名詞・略語を救済 |
| 辞書なし + 履歴なし | 0 | 0 | 考慮しない（1文字フォールバックへ） |

### DP アルゴリズム

```
dp[0] = 0
for i in 1...n:
  // 単一文字フォールバック（常に可能、スコア加算なし）
  if dp[i-1] >= 0:
    dp[i] = max(dp[i], dp[i-1])  // len=1 で score+=0

  // 辞書 or 履歴にある読み（length 2〜maxLen）
  // ※ i=1 のとき 2...1 は Swift でクラッシュするため stride を使う
  for len in stride(from: 2, through: min(i, maxLen), by: 1):
    j = i - len
    reading = chars[j..<i]
    score = dp[j] + totalScore(reading, len)
    if score > dp[i]:
      dp[i] = score
      segLen[i] = len

// バックトラックでセグメント列を復元
```

グリーディとの違い: 後続の分割も含めた**全体最適**を選ぶ。

---

## 変更ファイル一覧

| ファイル | 変更内容 |
|---|---|
| `Sources/DatabaseManager.swift` | `historyCount(reading:)` 追加、`segmentize` を DP に書き換え |
| `Tests/DatabaseManagerTests.swift` | DP + 履歴スコアリングのテスト追加 |

---

## Step 1: `DatabaseManager.swift`

### 変更 A: `historyCount` メソッド追加

`record()` の直前あたりに追加:

```swift
/// 指定の読みが過去にセグメントとして確定された合計回数を返す。
/// segmentize のスコアリングで使用。
func historyCount(reading: String) -> Int {
    let sql = "SELECT COALESCE(SUM(count), 0) FROM history WHERE input = ?"
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
    bindText(stmt, 1, reading)
    guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int(stmt, 0))
}
```

### 変更 B: `segmentize` を DP に書き換え

```swift
/// ひらがな文字列を DP + 履歴スコアリングで最適分割する。
/// score(seg) = (辞書マッチ長) + min(履歴使用回数, 4)
/// 辞書・履歴どちらにもない読みは単一文字フォールバックへ。
func segmentize(_ hiragana: String) -> [(reading: String, candidates: [String])] {
    let chars = Array(hiragana)
    let n = chars.count
    guard n > 0 else { return [] }
    let maxLen = 8

    // DP フェーズとバックトラックで fetchDict / historyCount の重複呼び出しを防ぐキャッシュ
    var dictCache: [String: [String]] = [:]
    var histCache: [String: Int]      = [:]

    // dp[i]: chars[0..<i] を分割したときの最大スコア（-1 = 未到達）
    var dp     = [Int](repeating: -1, count: n + 1)
    var segLen = [Int](repeating: 1,  count: n + 1)
    dp[0] = 0

    for i in 1...n {
        // 単一文字フォールバック（スコア加算なし）
        if dp[i - 1] >= 0 {
            dp[i] = dp[i - 1]
            segLen[i] = 1
        }

        // 辞書 or 履歴にある読み（2文字以上）
        // ※ i=1 のとき 2...1 は ClosedRange がクラッシュするため stride を使う
        for len in stride(from: 2, through: min(i, maxLen), by: 1) {
            let j = i - len
            guard dp[j] >= 0 else { continue }
            let reading = String(chars[j..<i])
            let dictCandidates = dictCache[reading] ?? {
                let c = fetchDict(reading: reading)
                dictCache[reading] = c
                return c
            }()
            let hist = histCache[reading] ?? {
                let h = historyCount(reading: reading)
                histCache[reading] = h
                return h
            }()
            let score = (!dictCandidates.isEmpty ? len : 0) + min(hist, 4)
            guard score > 0 else { continue }
            let candidate = dp[j] + score
            if candidate > dp[i] {
                dp[i] = candidate
                segLen[i] = len
            }
        }
    }

    // バックトラック（dictCache を再利用して fetchDict の2重呼び出しを回避）
    var result: [(reading: String, candidates: [String])] = []
    var i = n
    while i > 0 {
        let len = segLen[i]
        let reading = String(chars[(i - len)..<i])
        let candidates = dictCache[reading] ?? fetchDict(reading: reading)
        result.append((reading: reading, candidates: candidates))
        i -= len
    }
    return result.reversed()
}
```

---

## Step 2: テスト追加

### `Tests/DatabaseManagerTests.swift`

```
testSegmentizeDPPrefersMoreDictCoverage
  — Greedy が失敗するケース: "はなみずき"
    辞書に "はなみ" と "みずき" がある
    Greedy: ["はなみ", "ず", "き"] / DP: ["はな", "みずき"]
    → DP が辞書カバレッジの高い方を選ぶことを確認

testSegmentizeHistoryBoostsUnknownWord
  — 辞書にない "タワー" を履歴に入れると、
    "とうきょうタワー" が ["とうきょう", "タワー"] に分割されることを確認

testSegmentizeHistoryBoostsPreferredSplit
  — 履歴スコアで辞書スコアが同等の候補を逆転させることを確認
    （「タイブレーク」ではなく「履歴によるスコア引き上げで逆転」が主旨）

testSegmentizeNoHistoryFallsBackToDict
  — 履歴が空の場合、辞書スコアのみで分割される（Greedy 互換）
```

---

## 検討事項

### 単一文字セグメント（助詞）の扱い

現在の DP は `len >= 2` のみスコアが加算される。
「は」「が」「を」は1文字だが助詞として重要。ただし:

- 1文字に辞書マッチを許すと「は → 葉/刃/...」等の変換候補が出すぎる
- 助詞は通常ひらがなのまま確定されるので `histScore` でカバーできる可能性がある
- 現状維持（1文字はフォールバック）で様子を見て、必要なら後で拡張する

### histScore の上限と重み

`min(hist, 4)` の定数 `4` は調整余地あり。辞書スコア（最大 `len=8`）の半分程度を意図している。
実際の使用感を見て `8` に上げるか、`len / 2` の動的値にするか検討する。

### DP の計算量とキャッシュ

文字列長 `n`、最大セグメント長 `maxLen=8` として O(n × maxLen) 回のスコア評価が走る。
同一 reading が複数位置で出現する場合、ローカルキャッシュ（`dictCache` / `histCache`）で
`fetchDict` / `historyCount` の重複 SQL を防ぐ。
ユニークな reading 数 × 2 クエリ（最大でも数十）に収まり問題ない。

---

## 実施順序

1. `historyCount(reading:)` 追加
2. `segmentize` を DP に書き換え
3. テスト追加・全テスト通過確認
4. `/deploy` で実機確認（履歴なし状態での分割が既存と同等であること）
5. 実際に誤分割ケースを入力して履歴蓄積後の改善を確認
