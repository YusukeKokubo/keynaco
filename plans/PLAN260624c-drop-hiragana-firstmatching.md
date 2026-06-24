---
status: abandoned
created: 2026-06-24
related_rejected: R-2
---

# PLAN260624c: `isHiraganaPref` の `firstMatching` 分岐削除

## 背景

[PLAN260624b](PLAN260624b-resolver-explicit-cleanup.md) で resolver を削除した後、初期行決定に残った最後の特別分岐:

```swift
let initialRow: Int
if isHiraganaPref {
    initialRow = scoredLayout.candidates.firstIndex(of: h) ?? 0
} else {
    initialRow = 0
}
```

`hiraganaPreferred` 設定（userSetting / builtin）の reading に対して、scoreBuilder が hiraganaBonus（score 100 / 80）を加算するため、reading 行は普通 score 上位に来る。`firstIndex(of: h)` で明示的に取る分岐は理論上**冗長**。

## 実 DB での確認

`history.db` から `userSetting hiraganaPreferred` reading に対する非 reading 履歴の最高 score を確認:

| 種別 | bonus score | 衝突する履歴 max score | 結論 |
|------|------------|--------------------|------|
| userSetting | 100 | 7.9 (`ない`→`内`) → 10.001 | 100 勝ち |
| builtin | 80 | 6 (`て`→`手`) → 10.001 | 80 勝ち |

`firstMatching` 分岐があってもなくても row 0 に reading 行が来る。理論上 score 100 / 80 を超えるには 1 日に 50 回同 reading 漢字確定が必要（recencyShort 2 倍）で、実用上発生しない。

## 設計

```swift
let initialRow = 0
```

仕様は **「初期行は score 順先頭」** の一文に純化。

## Phase

- [x] **Phase 1**: hiraganaPreferred + 高 score 履歴で reading 行が score 上で row 0 に来るユニットテスト追加（exact のみで通った）
- [x] **Phase 2**: `isHiraganaPref` の `firstMatching` 分岐削除（実装→ロールバック）
- [x] **Phase 3**: sandbox で `の`/`は`/`ない`等の挙動が変わらないこと確認 → **`は`・`と`・`で`・`か` で prefix history が reading 行を上回る** ことが判明、ロールバック

## 結果

**Abandoned**: `docs/rejected.md` R-2 に記録。リスク評価で **prefix history の SUM スコア**を見落としたのが原因。実 DB の `LIKE 'は%'` で 100+ score の prefix history が出るケースが頻繁にあり、builtin bonus(80) を上回る。シンプル化で得る 4 行削減より、Space 1 打で助詞を入れる日常操作の一貫性が大事。

## スコープ外

- `isHiraganaPreferred(_:)` 関数自体（scoreBuilder への `hiraganaBonusKind` 引数決定に使うので残す）
- `hiraganaUserBonus = 100` / `hiraganaBuiltinBonus = 80` の値調整

## リスク

| リスク | 対策 |
|--------|------|
| 超ヘビー利用で history score が 100 を超える | 実 DB で発生せず（max 7.9）。発生したら「使い倒した漢字を出して欲しい」というユーザー意図とも合致するので問題なし |

## 関連

- [PLAN260624-unified-candidate-scoring.md](PLAN260624-unified-candidate-scoring.md)
- [PLAN260624b-resolver-explicit-cleanup.md](PLAN260624b-resolver-explicit-cleanup.md)
