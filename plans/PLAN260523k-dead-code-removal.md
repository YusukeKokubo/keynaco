# Step 1: dead code 削除（`mostRecentContentWord*`）

作成: 2026-05-23  
親計画: [`PLAN260523j-ime-simplification-phase3.md`](PLAN260523j-ime-simplification-phase3.md)

## ゴール

skip-bigram 廃止後に **本番コードから呼ばれなくなった** `mostRecentContentWord` / `mostRecentContentWords` / `committedContentWords` を削除する。

## 背景

- [`PLAN260503j-skip-bigram-multihop.md`](PLAN260503j-skip-bigram-multihop.md) で skip-bigram 多ホップ用に追加されたヘルパー
- skip-bigram テーブルは起動時 DROP 済み（[`DatabaseManager.swift`](../Core/Sources/Core/DatabaseManager.swift)）
- `rg mostRecentContentWord Core/Sources/Core` → **定義のみ**、呼び出しゼロ

## 削除対象

| 操作 | ファイル |
|------|----------|
| メソッド削除 | `Core/Sources/Core/InputHandler.swift` — `mostRecentContentWord()` / `mostRecentContentWords(n:)` / `committedContentWords(n:)` |
| テスト削除 | `Core/Sources/CoreTests/InputHandlerHistoryTests.swift` — `mostRecentContentWord*` 関連ケース（`testMostRecentContentWord*` 等） |

## 残すもの

- `InputHandler.particles` — Successor 格助詞 fallback と `committedHistory` 走査で使用中
- `committedHistory` / `pushCommitted` — Zenzai 左文脈・noun-bigram の prev 源

## ドキュメント

変更不要（glossary に `mostRecentContentWord` 節は元々ない）。古い plans / ideas の言及は歴史として残してよい。

## 検証

```bash
cd Core && swift test --filter InputHandlerHistory
cd Core && swift test
```

## リスク

**極低** — 本番呼び出しが存在しない dead code の削除のみ。

## 完了条件

- [ ] 3 メソッド削除
- [ ] 関連テスト削除・`swift test` パス
