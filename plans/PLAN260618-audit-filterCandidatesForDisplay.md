---
status: implemented
created: 2026-06-18
related_commit: d6a3267
---

# PLAN260618: filterCandidatesForDisplay の必要性検証

## 背景

`isScriptMixed` フィルタを削除した流れで（d6a3267）、`AzooKeyConverter.filterCandidatesForDisplay` も同種の「AzooKey 出力を絞り込む処理」として存在することが判明。こちらは 3 段フィルタで設計の意図はより明確だが、今の AzooKey でも同様に必要か未検証。

## 対象コード

`Core/Sources/Core/AzooKeyConverter.swift:282` の `filterCandidatesForDisplay`

```
1. fullCoverage     — 読み長と一致する候補のみ（予測変換を除外）
2. predictionFiltered — rubySum > inputLength かつ末尾が漢字でないものを除外（「蛇あ」「角煮ん」系）
3. validCoverage    — 末尾 1 文字かな + lcid 147〜554（機能語）を除外（残余助詞フィルタ）
```

`filtered.isEmpty ? candidates : filtered` のフォールバックがあり、フィルタ後が空の場合は生の候補を返す。

## 調査方針

sandbox でフィルタを一時無効化し、各段が今の AzooKey 出力で何を弾いているかを可視化する。

- フィルタ前後で候補リストがどう変わるか（件数・内容）
- 「蛇あ」「角煮ん」のような末尾残余が今でも出るか
- 残余助詞（「〜か」「〜に」等）が今でも出るか

## 判断基準

- 全段で弾かれる候補がゼロ → 削除候補
- 特定の段だけ有効 → その段だけ残す、または条件を絞る
- 今でも必要な候補が弾かれている → 修正を検討

## 調査結果（2026-06-18 sandbox 検証）

フィルタを `return candidates` でパススルーして 19 パターンを検証。

**フィルタが今でも有効に機能していることを確認。削除NG。**

弾かれている主な候補:
- `確認し`/`確認さ`（kakuni）、`実装さ`/`実装し`/`実装され`（jissou）、`入力し`/`入力する`/`入力して`（nyuuryoku）などの予測補完途中候補
- `ジ`、`ヵ`、`ニュ`、`ジッ` などの1文字・途中カタカナ

`isScriptMixed` とは異なり、AzooKey の仕様として予測補完候補は今でも返される。フィルタは今後も必要。

### 追加検証（2026-06-18）

「完全一致が上位に来るならフィルタ不要では？」という仮説で再検証。フィルタ無効時の順位:

| 入力 | 期待候補 | 順位 |
|------|---------|------|
| nyuuryoku | 入力 | 45位 |
| kakunin | 確認 | 205位（「角煮ん」が1位） |
| jissou | 実装 | 90位 |
| mananda | 学んだ | 86位 |
| wakatta | 分かった | 50位 |

AzooKey のスコアリングだけでは完全一致を上位に持ってこれない。フィルタが完全一致優先を実質的に担っている。削除NG 確定。
