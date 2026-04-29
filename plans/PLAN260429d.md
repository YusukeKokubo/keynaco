# PLAN260429d: A-2 ユーザー辞書の前方一致対応

## 概要

ユーザー辞書の候補表示を「完全一致のみ」から「完全一致 + 前方一致」に拡張する。
履歴は `recordPrefixes` で前方一致に対応しているのに、ユーザー辞書だけ完全一致というのは一貫性がない。
「とうきょうと」と打ったとき「とうきょう」登録の「東京」が候補に出ない問題を解消する。

---

## 現状

`DatabaseManager.fetchUserDict(reading:)` は `WHERE input = ?`（完全一致）のみ。

```swift
// buildCandidateList() での呼び出し
let userDictRaw = db.fetchUserDict(reading: historyKey)
```

`buildSegmentCandidates()` はユーザー辞書を参照しない（セグメントモードは対象外とする）。

---

## 実装方針

### 1. `DatabaseManager` に `fetchUserDictPrefix` を追加

```swift
/// 読みが前方一致するユーザー辞書候補を返す（完全一致は除外）。
func fetchUserDictPrefix(reading: String) -> [String] {
    return queryStrings("""
    SELECT output FROM user_dict
    WHERE input LIKE ? AND input != ?
    ORDER BY id ASC
    """) {
        self.bindText($0, 1, reading + "%")
        self.bindText($0, 2, reading)
    }
}
```

- `LIKE` は大文字小文字を区別しない（SQLite デフォルト）。ASCII 読みのユーザー辞書に対応。
- `input != ?` で完全一致を除外（完全一致は `fetchUserDict` が取得済み）。
- 登録順（`id ASC`）を維持。時間減衰なし（`user_dict` テーブルの設計方針）。

### 2. `buildCandidateList()` を更新

```swift
// Before
let userDictRaw = db.fetchUserDict(reading: historyKey)

// After
let userDictExact = db.fetchUserDict(reading: historyKey)
let userDictPrefix = db.fetchUserDictPrefix(reading: historyKey)
let userDictRaw = userDictExact + userDictPrefix.filter { !userDictExact.contains($0) }
```

- 完全一致を前方一致より優先（完全一致を先頭に配置）。
- `fixedEnd` の計算は `uniqueUserDict.count` を使う既存ロジックのままで正しい。
- `autoShow` の判定 `userDictRaw.isEmpty` も自動的に前方一致を含む判定になる。

### 変更ファイル

| ファイル | 変更内容 |
|---------|---------|
| `Sources/DatabaseManager.swift` | `fetchUserDictPrefix(reading:)` を追加（`// MARK: - ユーザー辞書` セクション） |
| `Sources/InputHandler+Candidates.swift` | `buildCandidateList()` のユーザー辞書取得を2段階に変更 |

---

## テスト

`Tests/DatabaseManagerTests.swift` に追加:
- `fetchUserDictPrefix("とうきょう")` が「とうきょうと」登録の候補を返すこと
- `fetchUserDictPrefix("とうきょう")` に完全一致「とうきょう」登録の候補が含まれないこと
- `buildCandidateList` の結合テスト: 完全一致の候補が前方一致の候補より前に来ること

---

## 考慮事項

- セグメントモード（`buildSegmentCandidates`）はユーザー辞書を参照しないまま据え置く。
  セグメントの読みは入力の一部分であり、完全一致で引ける（"きょう" → "今日" のユーザー辞書登録など）。
  前方一致まで広げるとセグメント候補が増えすぎて選択しにくくなる。
- `fetchUserDictPrefix` の `LIKE` パターンは `reading + "%"` のみで、内部一致（`%reading%`）はしない。
  語頭から一致する場合のみ補完するのが自然な IME の挙動。
- `user_dict` に大量登録している場合、`LIKE` クエリのコストが増えるが、
  `idx_user_dict ON user_dict(input)` インデックスが前方一致 LIKE に効くため許容範囲。

---

## 規模見積もり

1〜2時間（実装 30分 + テスト 30分 + 動作確認 30分）。
