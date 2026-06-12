# ひらがな優先語彙リスト（hiraganaPreferred）

## 背景

格助詞（「の」「に」等）は変換履歴に「ノックアウト」等が積み上がっても、
ひらがな固定候補を初期選択にしてほしい。

`954e2ea` で `particles` による格助詞限定の修正を入れたが、
接続詞・口語表現等もひらがなで書くのが自然な語彙が多く、
同じ問題が発生しうる。また `954e2ea` 自体に既存バグがある（後述）。

## 目的

「ひらがなで書くのが自然な語彙」を `hiraganaPreferred` として一元管理し、
それらが入力されたときは履歴スコアに関係なくひらがな候補を初期選択にする。
予測候補（bi-gram 等）があっても同様にひらがな優先とする。

常にひらがな row を優先する仕様とする（漢字候補を選ぶことが稀な語のみ対象）。
リスト外の語は従来通り履歴・予測候補を優先する。

## 既存バグ（`954e2ea`）

`hiraganaInHistory=true` のとき（「の」等がひらがな履歴として蓄積されると発生）、
固定枠には「ノ」のみが残りひらがな「の」は履歴セクションへ移動する。
しかし現行の `initialRow = 0` は「ノ」（カタカナ）を指してしまう。

```
row0: ノ [fixed]      ← initialRow=0 でカタカナが選ばれる
row1: の [history]    ← 本来選ばれるべき
```

本計画の実装でこのバグも合わせて修正する。

## 設計

### `hiraganaPreferred: Set<String>` を `InputHandler` に追加

`particles` の上位集合として `particles` から派生させて定義する。
`particles`（bigram の文脈スキップ判定・Successor fallback に使用）は意味が別なので残す。

```swift
public static let hiraganaPreferred: Set<String> = Set(particles + [
    // 接続助詞・副助詞
    "けど", "けれど", "ので", "ながら", "でも", "ても",
    // 接続詞
    "そして", "しかし", "また", "ただ", "では",
    // 指示語
    "これ", "それ", "あれ", "ここ", "そこ", "あそこ",
    // 口語・前置き
    "ちょっと", "とか", "とりあえず", "なんか",
    // 副助詞（regex にはあったが Set 未収録だったもの）
    "だけ", "など",
])
```

### 既存 `isHiraganaPreferred` / `hiraganaPreferredRegex` の整理

`InputHandler+Candidates.swift` に regex ベースの未使用実装が残っている。
regex は `している` 等の末尾パターンをカバーするが `initialRow` 判定には過剰であり、
デッドコードなので両方削除して Set のみに一本化する（案B）。
形態素パターン（`している` 等）への対応は本スコープ外とする。

### `initialRow` の新ロジック（案A）

`isHiraganaPreferred` な語は、候補リスト中のひらがな（`h` そのもの）の位置を
`initialRow` にする。固定枠にあれば row 0、履歴枠に移動していれば
`candidates.firstIndex(of: h)` の行になる。

```swift
static func isHiraganaPreferred(_ h: String) -> Bool {
    InputHandler.hiraganaPreferred.contains(h)
}

// assembleCandidateList 内
let initialRow: Int
if Self.isHiraganaPreferred(h) {
    // ひらがなが候補リスト内のどこにあっても常にひらがなを初期選択にする
    initialRow = candidates.firstIndex(of: h) ?? 0
} else {
    initialRow = historyEnd > adjustedFixedEnd ? adjustedFixedEnd : 0
}
```

`firstIndex(of:)` が `nil` になるのは `shouldPromoteFirstDict` によりひらがな固定候補が
存在しないケース（ひらがなが辞書候補に降りている）。その場合は 0 でよい。

### `isParticleInput` の廃止

`954e2ea` で追加した `isParticleInput` を削除し、`Self.isHiraganaPreferred(h)` に統一する。

## 変更ファイル

| ファイル | 変更内容 |
|---------|---------|
| `Core/Sources/Core/InputHandler.swift` | `hiraganaPreferred` 定数を追加 |
| `Core/Sources/Core/InputHandler+Candidates.swift` | `hiraganaPreferredRegex` / 旧 `isHiraganaPreferred` を削除、新 `isHiraganaPreferred` を追加。`isParticleInput` を廃止し `initialRow` ロジックを更新 |
| `Core/Sources/CoreTests/InputHandlerCandidatesTests.swift` | テストを追加（下記） |
| `docs/domain/glossary.md` | `hiraganaPreferred` と `particles` の役割分担を追記 |

## テスト方針

`initialRow` を直接アサートする（`selectedText` より Core テストとして堅い）。

1. **格助詞＋誤履歴の回帰**: `recordPrefixes(reading: "の", output: "ノックアウト")` 後に「の」入力 → `initialRow == 0`（ひらがな固定）
2. **格助詞＋ひらがな履歴**: 「の」ひらがなを履歴シード後に「の」入力 → `initialRow` が「の」のインデックス（カタカナ「ノ」が row 0 にならない）
3. **新規語彙**: 「とか」「では」「これ」で履歴シード後でも `initialRow` がひらがなの位置
4. **非優先語の回帰**: 「あい」等は履歴候補があれば `initialRow == adjustedFixedEnd`（既存テスト維持）
