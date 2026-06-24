---
status: in-progress
created: 2026-06-24
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

- [x] **Phase 1**: hiraganaPreferred + 高 score 履歴で reading 行が score 上で row 0 に来るユニットテスト追加
- [x] **Phase 2**: `isHiraganaPref` の `firstMatching` 分岐削除（一度ロールバック → ユーザー指摘で再適用）
- [x] **Phase 3**: sandbox で実動線確認

## 経緯と教訓

### 一度 abandoned → 再開した

最初の Phase 3 sandbox で「`は`・`と`・`で`・`か` で Space を押すと row 0 が漢字（`話`/`取引先`/`できる`/`確認して`）になる」のを観測し、`docs/concept.md` 指針 1 (機能語サジェスト) と衝突すると判断してロールバック・`rejected.md` R-2 として記録した。

ユーザー指摘で再検証したところ、**助詞入力の実動線が Space を経由しない**ことが判明:

| 操作 | 候補窓 | 結果 |
|------|--------|------|
| `ha` + Enter（実動線） | 出ない（whileTyping で builtin dismiss） | `は` 確定 |
| `ha` + Space + Enter（普段やらない操作） | 出る、selectedRow が変化 | 旧:`は` / 新:`話` |

`whileTyping` の builtin dismiss が S1 適用前後で不変。Space を意図的に押すのは「変換意図」なので、漢字側が row 0 になる方がむしろ Space の意味と一貫する。

### 教訓

- 「動線」を sandbox で検証する時は **ユーザーが実際にやる操作シーケンス**で見る。`ha + Space + 観察` は分析用の操作で、実動線ではない
- 設計意図 (「助詞は候補ウィンドウなしで Enter 確定するために hiraganaPreferred リストを作った」) を確認せず、観察した状態から動線を逆推論したのが間違い
- `R-2` rejected エントリは撤回（仕様シンプル化に成功したと結論を訂正）

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
