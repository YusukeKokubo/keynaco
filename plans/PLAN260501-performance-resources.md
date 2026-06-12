# PLAN260501: パフォーマンス・リソース節約

## 概要

キー入力レイテンシの削減とメモリ使用量の抑制を目的とした改善。
変更量が少なく効果が高い順に実施する。

---

## 改善一覧

| # | 内容 | 変更量 | 優先度 |
|---|------|--------|--------|
| A | `candidateCache` にサイズ上限（LRU 50件） | 小 | P0 |
| B | 重複排除の `contains` → `Set` 化（O(n²) → O(n)） | 小 | P0 |
| C | `punctuationMap` を `static let` に昇格 | 極小 | P0 |
| D | AzooKey 呼び出しを composedHiragana が変わったときだけに制限 | 小 | P1 |
| E | `EventViewerWindow` の呼び出しを `#if DEBUG` で囲む | 極小 | P1 |

---

## A. `candidateCache` にサイズ上限（LRU 50件）

**ファイル**: `Sources/AzooKeyConverter.swift`

### 問題

`candidateCache: [String: [Candidate]]` はエントリを削除しない。
`segmentize()` はひらがな断片ごとにキャッシュを追加するため、セグメントモードを使うほど膨れ続ける。
長時間起動した状態でメモリ使用量が増加し続ける。

### 実装方針

Swift 標準ライブラリに LRU キャッシュはないため、`OrderedDictionary` の代わりに
挿入順を `[String]` で管理するシンプルな LRU を追加する。

```swift
private var candidateCache: [String: [Candidate]] = [:]
private var candidateCacheKeys: [String] = []  // 挿入順（古い順）
private let candidateCacheLimit = 50

private mutating func insertCache(key: String, value: [Candidate]) {
    if candidateCache[key] != nil {
        candidateCacheKeys.removeAll { $0 == key }
    } else if candidateCache.count >= candidateCacheLimit {
        let evict = candidateCacheKeys.removeFirst()
        candidateCache.removeValue(forKey: evict)
    }
    candidateCache[key] = value
    candidateCacheKeys.append(key)
}
```

`requestCandidates` / `candidatesForSegment` / `segmentize` の
`candidateCache[key] = ...` を `insertCache(key:value:)` に置き換える。

---

## B. 重複排除の `contains` → `Set` 化

**ファイル**: `Sources/InputHandler+Candidates.swift`, `Sources/InputHandler+SuccessorMode.swift`

### 問題

`buildCandidateList()` と `suggestSuccessors()` で `Array.contains` による重複排除が多数あり、
候補数 n に対して O(n²) になっている。

```swift
// 現状（O(n²)）
let historyCandidates = exactCandidates + prefixCandidates.filter { !exactCandidates.contains($0) }
let predictRaw = trigramRaw + bigramRaw.filter { !trigramRaw.contains($0) }
    + skipBigramRaw.filter { !trigramRaw.contains($0) && !bigramRaw.contains($0) }
var candidates = historyCandidates + azooKeyCandidates.filter { !historyCandidates.contains($0) }
let uniquePredictions = predictRaw.filter { !candidates.contains($0) }
```

### 実装方針

`seen: Set<String>` を使って挿入済みチェックを O(1) にする。
順序を保持したまま重複排除するユーティリティを局所的に使う。

```swift
// 変更後
func deduplicated(_ arrays: [String]...) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for arr in arrays {
        for s in arr where seen.insert(s).inserted {
            result.append(s)
        }
    }
    return result
}

let historyCandidates = deduplicated(exactCandidates, prefixCandidates)
let predictRaw = deduplicated(trigramRaw, bigramRaw, skipBigramRaw)
var candidates = deduplicated(predictRaw, historyCandidates, azooKeyCandidates)
```

`suggestSuccessors()` の同パターン（`SuccessorMode.swift:21`）も同様に修正する。

---

## C. `punctuationMap` を `static let` に昇格

**ファイル**: `Sources/InputHandler+Candidates.swift:306`

### 問題

`handlePunctuation()` の関数ローカルで毎回辞書リテラルを生成している。

```swift
// 現状（毎呼び出しでアロケーション）
let punctuationMap: [String: String] = [",": "、", ".": "。"]
```

### 実装方針

`extension InputHandler` の `static let` に移動するだけ。

```swift
static let punctuationMap: [String: String] = [",": "、", ".": "。"]
```

---

## D. AzooKey 呼び出しを composedHiragana が変わったときだけに制限

**ファイル**: `Sources/InputHandler+Candidates.swift`, `Sources/InputHandler.swift`

### 問題

`buildCandidateList()` が呼ばれるたびに `azooKeyConverter.requestCandidates(hiragana:)` が実行される。
候補ウィンドウ表示中に ↑↓ や Tab でナビゲートするだけでも毎回呼ばれ、
`composedHiragana` が変わっていないのに同じ結果を再計算している。

### 実装方針

`InputHandler` に最後のAzooKey入力と結果をキャッシュする変数を追加する。

```swift
// InputHandler.swift に追加
private var lastAzooKeyInput: String = ""
private var lastAzooKeyResults: [String] = []
```

`buildCandidateList()` での呼び出しを以下のように変更する。

```swift
let azooKeyCandidates: [String]
if h.allSatisfy({ $0.isASCII }) {
    azooKeyCandidates = []
    lastAzooKeyInput = ""
    lastAzooKeyResults = []
} else if h == lastAzooKeyInput {
    azooKeyCandidates = lastAzooKeyResults
} else {
    azooKeyCandidates = azooKeyConverter.requestCandidates(hiragana: h)
    lastAzooKeyInput = h
    lastAzooKeyResults = azooKeyCandidates
}
```

composedHiragana をクリアする処理（`commitText`、`doEscape` 等）で
`lastAzooKeyInput = ""` もリセットする。

---

## E. `EventViewerWindow` 呼び出しを `#if DEBUG` で囲む

**ファイル**: `Sources/InputController.swift`

### 問題

`EventViewerWindow.shared.addEvent(...)` と `addCandidates(...)` と `updateResult(...)` が
毎キー入力で本番ビルドでも実行される。デバッグ画面を閉じていても呼び出しコストがある。

### 実装方針

該当箇所を `#if DEBUG` ブロックで囲む。

```swift
#if DEBUG
EventViewerWindow.shared.addEvent(
    keyCode: event.keyCode, chars: chars, baseChars: baseChars,
    mods: mods, bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
)
#endif
```

`project.yml` の Debug 設定に `OTHER_SWIFT_FLAGS: -DDEBUG` が既に入っているか確認する。
入っていなければ追加する。

---

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `Sources/AzooKeyConverter.swift` | LRU キャッシュ機構を追加 |
| `Sources/InputHandler+Candidates.swift` | Set 重複排除・AzooKey キャッシュ・punctuationMap static 化 |
| `Sources/InputHandler+SuccessorMode.swift` | Set 重複排除 |
| `Sources/InputHandler.swift` | AzooKey キャッシュ変数追加・リセット処理 |
| `Sources/InputController.swift` | EventViewerWindow 呼び出しを `#if DEBUG` で囲む |
| `project.yml` | 必要なら `-DDEBUG` フラグ確認・追加 |

---

## テスト方針

- B の重複排除変更は `buildCandidateList` のテストが通れば十分（候補の順序が変わらないことを確認）
- D の AzooKey キャッシュは `MockAzooKeyConverter` を使ってキャッシュヒット時に呼ばれないことを検証
- A・C・E はロジック変更がないため既存テストが通ることで確認

---

## 規模見積もり

2〜3時間（A: 45分, B: 30分, C: 5分, D: 45分, E: 15分, テスト確認: 30分）。
