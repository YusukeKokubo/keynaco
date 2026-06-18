---
status: draft
created: 2026-06-18
---

# PLAN260618b: セグメント情報を活用した候補フィルタ改善

## 背景

`filterCandidatesForDisplay` は AzooKey が返す候補の `Candidate.data: [DicdataElement]`
（形態素セグメントのリスト）を内部で参照しているが、`requestCandidates` の返り値が
`[String]` のため呼び出し側はセグメント構造を知る手段がない。

また現在のフィルタは lcid 147〜554 という数値範囲で機能語を判定しており、意図が不透明。
セグメント数を明示的に扱えばより読みやすく・正確なフィルタになる。

関連: [[PLAN260618-audit-filterCandidatesForDisplay]]

## 方針

### Phase 1: セグメント情報を型に出す（B）

`requestCandidates` の返り値に `segmentCount`（と必要なら各セグメントの情報）を含める。

候補の返り値の型を `[String]` から構造体に変更し、最低限 `text` と `segmentCount` を持つ。
将来の候補表示（セグメント境界の可視化など）への布石にもなる。

```swift
public struct AzooKeyCandidate: Sendable {
    public let text: String
    public let segmentCount: Int   // data.count
    // 必要なら: public let segments: [(word: String, ruby: String, lcid: Int)]
}
```

影響範囲: `AzooKeyConverter.requestCandidates` の返り値・呼び出し箇所
（`InputHandler+Candidates.swift` の `azooKeyCandidates`、`peekCachedCandidates` 等）

### Phase 2: フィルタをセグメント数ベースに書き直す（A）

`filterCandidatesForDisplay` の `validCoverage` 段（lcid 147〜554 の数値判定）を
`segmentCount == 1` を使った判定に置き換える。

```
現在: data.count > 1 && 末尾が1文字かな && lcid in 147...554
改善: segmentCount == 1 → 無条件で残す
      segmentCount >= 2 → 末尾が漢字なら残す（内容語補完）、それ以外は弾く
```

「確認」（1セグメント）→ 残す
「角煮ん」（2セグメント、末尾かな）→ 弾く
「内閣府」（2セグメント、末尾漢字）→ 残す

## 注意点

- `primaryLcidByText`（lcid ソート用）は内部で `Candidate.data` を参照しているので
  Phase 1 の型変更と合わせて整合を確認する
- `AzooKeyCachePeek` も `[String]` を持つので影響を確認する
- Phase 1 → Phase 2 の順で進める
