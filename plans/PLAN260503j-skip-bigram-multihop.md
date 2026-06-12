# skip-bigram 多ホップ ✅ 実装完了（2026-05-03）

## 目的

現状 skip-bigram は「直前助詞の1語前のコンテンツワード」だけを記録・検索している。
「2語前のコンテンツワード」まで範囲を広げ、遠位語の共起をキャプチャする。

## 変更が必要な箇所（5箇所）

| 箇所 | ファイル | 現状 | 変更後 |
|------|---------|------|--------|
| 記録 | `InputHandler.swift` | `mostRecentContentWord()` → 1件 | `mostRecentContentWords(n: 2)` → ループ |
| Backspace ペナルティ | `DatabaseManager.swift` `penalizeAll` | `skipPrev: String?` → 1件 | `skipPrevs: [String]` → ループ |
| 通常変換予測 | `InputHandler+Candidates.swift` | `mostRecentContentWord()` → 1語 | `mostRecentContentWords(n: 2)` → merged |
| Successor 初期検索 | `InputHandler+SuccessorMode.swift` L44 | 1語で fetch | 複数語でflatMap→merge |
| 1打目フィルタ | `InputHandler+SuccessorMode.swift` L177 | 1語で fetch | 複数語でループ |

## 変更箇所

### 1. `mostRecentContentWords(n:)` の追加（`InputHandler.swift`）

```swift
func mostRecentContentWords(n: Int) -> [String] {
    guard committedHistory.count >= 2 else { return [] }
    var result: [String] = []
    for i in stride(from: committedHistory.count - 2, through: 0, by: -1) {
        if !InputHandler.particles.contains(committedHistory[i]) {
            result.append(committedHistory[i])
            if result.count >= n { break }
        }
    }
    return result
}
```

既存の `mostRecentContentWord()` は `mostRecentContentWords(n: 1).first` に委譲してもよいが、
呼び出し箇所が多いため、`mostRecentContentWords` を追加し既存メソッドはそのまま残す。

### 2. 記録側（`InputHandler.swift` L300付近）

`capSkipPrev: String?` を `capSkipPrevs: [String]` に変更し、
`recordNgrams` の `skipBigram: Optional` を `skipBigrams: [...]` に変更して1トランザクションに収める。

```swift
// before
var capSkipPrev: String?
if InputHandler.particles.contains(p1) { capSkipPrev = mostRecentContentWord() }
db.recordNgrams(
    bigram: ...,
    trigram: ...,
    skipBigram: capSkipPrev.map { (prev: $0, input: bigramInput, output: text) }
)

// after
var capSkipPrevs: [String] = []
if InputHandler.particles.contains(p1) { capSkipPrevs = mostRecentContentWords(n: 2) }
db.recordNgrams(
    bigram: ...,
    trigram: ...,
    skipBigrams: capSkipPrevs.map { (prev: $0, input: bigramInput, output: text) }
)
```

`LastConfirmedContext` の `skipPrev: String?` フィールドも `skipPrevs: [String]` に変更する。

### 3. `DatabaseManager.recordNgrams()` の変更

```swift
// before
skipBigram: (prev: String, input: String, output: String)?

// after
skipBigrams: [(prev: String, input: String, output: String)]
```

ループで INSERT するだけ（既存の skip-bigram INSERT SQL をそのまま繰り返す）。

### 4. Successor 初期検索（`InputHandler+SuccessorMode.swift` L44）

```swift
// before
let skipBigramTop = mostRecentContentWord().map { db.fetchSkipBigramTop(prev: $0) } ?? []

// after
let skipBigramTop = mostRecentContentWords(n: 2)
    .map { db.fetchSkipBigramTop(prev: $0) }
    .reduce([]) { InputHandler.merged($0, $1) }
```

`reduce` の先頭配列（より近いコンテンツワード）が `merged` で優先される。

### 5. 通常変換予測（`InputHandler+Candidates.swift`）

```swift
// before
let skipBigramRaw = mostRecentContentWord().map {
    db.fetchSkipBigram(prev: $0, reading: state.composedHiragana)
} ?? []

// after
let skipBigramRaw = mostRecentContentWords(n: 2).flatMap {
    db.fetchSkipBigram(prev: $0, reading: state.composedHiragana)
}
```

重複除去は `merged(trigramRaw, bigramRaw, skipBigramRaw)` が担う。

### 6. `DatabaseManager.penalizeAll()` の変更

確定直後 Backspace（誤変換訂正）で `skipPrev: String?` を1件だけペナルティしているが、
記録が `skipPrevs: [String]` になると2件記録→1件しか巻き戻らない不整合になる。
`LastConfirmedContext` の `skipPrevs: [String]` をそのままループする。

```swift
// before
if let sp = skipPrev { /* UPDATE + DELETE */ }

// after
for sp in skipPrevs { /* 同じ UPDATE + DELETE */ }
```

`penalizeAll` の呼び出し元は `doBackspace` と Successor 内の2箇所。どちらも `LastConfirmedContext`
経由なので、`skipPrevs` 型変更に追随するだけでよい。

### 7. 1打目フィルタ（`InputHandler+SuccessorMode.swift` L177付近）

```swift
// before
let contentWordForFilter = mostRecentContentWord()
...
let fromSkip = contentWordForFilter.map {
    db.fetchSkipBigram(prev: $0, reading: kana)
} ?? []

// after
let fromSkip = mostRecentContentWords(n: 2).flatMap {
    db.fetchSkipBigram(prev: $0, reading: kana)
}
```

重複除去は直後の `filteredSeen` ループが担うので追加処理不要。

## テスト方針

- `mostRecentContentWords(n:)` の単体テスト
  - 履歴が2件未満 → 空配列
  - `n=1` → `mostRecentContentWord()` と同一結果
  - `n=2` で連続助詞をまたいで2語取得できるか
  - コンテンツワードが1語しかない場合 → 1件のみ返す（n=2 でも 2件強制しない）
- `recordNgrams(skipBigrams:)` の DB テスト（`inMemory: true`）
  - 2件渡して両方 skip_bigram に記録されることを確認
- `penalizeAll` のテスト
  - `skipPrevs` に2件渡し、両方のペナルティが適用されることを確認

## 実装順序

1. `mostRecentContentWords(n:)` 追加 + テスト
2. `DatabaseManager.recordNgrams` の `skipBigrams` 変更 + `penalizeAll` の `skipPrevs` 変更
3. `InputHandler.commitText` の記録側更新（`capSkipPrevs`・`LastConfirmedContext` 変更含む）
4. `InputHandler+Candidates` の通常変換予測更新
5. `InputHandler+SuccessorMode` の Successor 初期検索更新
6. `InputHandler+SuccessorMode` の1打目フィルタ更新
7. ビルド確認 → テスト実行

## 工数目安

半日（変更行数は少ないが `LastConfirmedContext` 周辺の型変更が波及するため）
