---
status: implemented
created: 2026-06-17
---

# PLAN260617: `rankForPrefixFocus` の多段フォールバック簡略化

## 目的

`InitialRowPolicyResolver.rankForPrefixFocus` の Branch 3–4（`lcidForCommitted` 呼び出しパス）を削除し、キー打鍵ごとの余分な AzooKey 辞書フルサーチをなくす。

## 背景

`rankForPrefixFocus` は 4 段のフォールバックで品詞ランクを解決する。

```
Branch 1: db.lcidForOutput(output)            → SQLite 1クエリ（通常はここで終わる）
Branch 2: db.posForOutput(output)             → SQLite 1クエリ
Branch 3: db.longestInputForOutput(output)
           + azooKey.lcidForCommitted(...)    → SQLite 1クエリ + AzooKey辞書フルサーチ + NSLock
Branch 4: azooKey.lcidForCommitted(readingHint, output)
                                              → AzooKey辞書フルサーチ + NSLock
```

調査結果:

- **通常時**: `schedulePOSClassification`（確定時に非同期実行）+ 起動時 backfill により、ほぼすべての履歴エントリに `lcid` が設定済み。Branch 1 で終わる。
- **Branch 3–4 がヒットする条件**: 確定直後でまだ非同期分類が完了していない短い窓、または AzooKey 辞書にない語（造語・未収録固有名詞等）。
- **AzooKey 辞書にない語の場合**: Branch 3 で `lcidForCommitted` を呼んでも nil が返り、Branch 4 も同様に失敗して `.unknown` に落ちる。コストだけかかって結果が変わらない。
- **Branch 4 が Branch 3 と異なる結果を返す条件**: Branch 3 の reading（履歴最長 input）で失敗し、`readingHint`（現在の組成読み）で成功するケース。AzooKey 辞書にない語が Branch 3 で失敗している以上、Branch 4 も同じ語で失敗する可能性が高く、実質ほぼ無駄打ち。

さらに `prefixFocusCandidate` と `whileTypingInitialRow` の両方から同じクロージャが呼ばれ、同一候補に対してキャッシュなしで 2 回 DB/辞書問い合わせが走る。

## 変更方針

`rankForPrefixFocus` を Branch 1–2 だけに簡略化する。

```swift
// Before
static func rankForPrefixFocus(output: String, db: DatabaseManager, azooKey: AzooKeyConverting, readingHint: String = "") -> LcidRank {
    if let lcid = db.lcidForOutput(output) { return LcidRank.from(lcid: lcid) }
    if let pos = db.posForOutput(output) { return LcidRank.from(pos: pos) }
    if let input = db.longestInputForOutput(output),
       let lcid = azooKey.lcidForCommitted(reading: input, output: output) {
        return LcidRank.from(lcid: lcid)
    }
    if !readingHint.isEmpty,
       let lcid = azooKey.lcidForCommitted(reading: readingHint, output: output) {
        return LcidRank.from(lcid: lcid)
    }
    return .unknown
}

// After
static func rankForPrefixFocus(output: String, db: DatabaseManager) -> LcidRank {
    if let lcid = db.lcidForOutput(output) { return LcidRank.from(lcid: lcid) }
    if let pos = db.posForOutput(output) { return LcidRank.from(pos: pos) }
    return .unknown
}
```

シグネチャから `azooKey` と `readingHint` パラメータも除去し、呼び出し側 `InputHandler+Candidates.swift` の `prefixFocusRank` クロージャも簡略化する。

## 影響範囲

- `InitialRowPolicyResolver.rankForPrefixFocus` シグネチャ変更
- `InputHandler+Candidates.swift` の `prefixFocusRank` クロージャ（`azooKey` 参照を渡さなくなる）
- `DatabaseManager+History.swift` の `longestInputForOutput` — 他の呼び出し元がなければ削除候補

## 期待される動作変化

`lcid` も `pos` も DB にないエントリが `.unknown`（5 モーラ必要）扱いになる。

主に影響するのは**ユーザー辞書の未確定エントリ**。`addUserDict` は辞書行を作るだけで `history` テーブルに pos/lcid を書かないため、一度も確定していない語は Branch 1–2 で品詞が取れない。現状は Branch 4 で AzooKey lookup して補っている。

本件ではこの退行を受け入れ、テスト `testWhileTyping_userDictPrefixFocusesNoun` を「4 モーラでフォーカスしない」期待値に更新する。

根本対処（本件スコープ外）: ユーザー辞書登録時（`addUserDict`）に `AzooKeyPOSClassifier.classify` を走らせて `history` テーブルに pos/lcid を書く。そうすれば Branch 1 でヒットするようになり、登録直後から正しくフォーカスされる。

履歴の確定直後（`schedulePOSClassification` 完了前の短い窓）も同様に `.unknown` 扱いになるが、これは PLAN260614 の「既知の限界」として記録済みの挙動と同じ。

## 検証方針

1. `./scripts/test_core.sh` — テスト `testWhileTyping_userDictPrefixFocusesNoun` の期待値を「4 モーラではフォーカスしない」に変更した上で全パス確認
2. PLAN260614 の sandbox シナリオを再走（`/keynaco-ime-sandbox`）
   - 動詞 `たべ`（2m）→ フォーカスしない
   - 名詞 `とうきょ`（3m）→ 「東京」にフォーカス（`lcid` 設定済み前提）
   - 直後確定語（`pos`/`lcid` なし）→ `.unknown` 扱い（5m 必要）、期待内

## 関連

- 対象コード: [PLAN260614-prefix-focus-mora-thresholds.md](PLAN260614-prefix-focus-mora-thresholds.md)（本件の前提実装）
- 後続: ユーザー辞書登録時の pos/lcid 書き込み（本件で発覚した根本問題）
