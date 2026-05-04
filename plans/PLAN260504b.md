# IMKTextInput 経由でカーソル前後テキストを取得して LLM 文脈を強化する

## 目的

現在の `LLMCandidateScorer` / `LLMSuccessorFetcher` は `committedHistory`（同一文内の確定語）と
`surroundingText(maxLength:)` を文脈として使っているが、後者は IME 独自のアダプタ経由の取得であり、
アプリによっては空になる。

`IMKTextInput` プロトコルの `attributedSubstring(from:)` と `length()` を直接呼ぶことで、
**クライアントアプリが保持している実際のテキスト**（カーソル前後）を取得し、より豊かな文脈を
LLM プロンプトに渡せるようにする。

> **備考**: 現行アダプタ（`IMKTextInputAdapter`）は `string(from:actualRange:)` を使っている。
> `attributedSubstring(from:)` との差は「どのクライアントで一方が空で他方が非空になるか」が
> アプリ依存のため、両 API の結果を並行ログで比較しながら効果を検証すること。

## 安全な実装上の制約

`NSRange` の計算に起因するクラッシュを防ぐため、以下の3点を必ず守る。

### 1. NSNotFound ガード

`selectedRange().location` は未フォーカス時などに `NSNotFound`（`Int.max` 相当の大値）を返す。
この値を四則演算に使うとオーバーフローして異常終了する。

```swift
let range = client.selectedRange()
guard range.location != NSNotFound else { return nil }
```

### 2. `beforeLength` は実際の文字数で計算

開始位置を `max(0, range.location - N)` にずらした場合、`length` は固定値 `N` ではなく
`range.location - beforeLocation` で算出する。固定値にするとカーソル前に N 文字未満しかない
場合にカーソル後のテキストまで巻き込む。

```swift
let beforeLocation = max(0, range.location - 300)
let beforeLength = range.location - beforeLocation   // 実際の文字数
```

### 3. `afterLength` は `client.length()` でクランプ

`client.length()` も `NSNotFound` を返しうるので確認してからクランプする。
無条件に `length: 300` を渡すと文書末尾を超えて `NSRangeException` でクラッシュする
クライアントアプリがある。

```swift
let totalLength = client.length()
guard totalLength != NSNotFound, totalLength >= range.location + range.length else { return nil }
let afterLocation = range.location + range.length
let afterLength = min(300, totalLength - afterLocation)
```

> **技術メモ**: `NSRange` の単位は UTF-16 コードユニットであることが多く、
> 「最大 300 ユニット」が「300 文字」とは限らない（絵文字等は2ユニット占める）。
> 既存の `surroundingText` と挙動が揃えば実用上は問題ない。
> `beforeLength == 0`（文頭）でも `attributedSubstring` を呼んで空文字が返ることをテストで確認する。

### 完全な安全実装

```swift
func fetchSurroundingContext(from sender: Any) -> (before: String, after: String)? {
    guard let client = sender as? IMKTextInput else { return nil }
    let range = client.selectedRange()
    guard range.location != NSNotFound else { return nil }

    // カーソル前 N 文字
    let beforeLocation = max(0, range.location - 300)
    let beforeLength = range.location - beforeLocation
    let before = client.attributedSubstring(
        from: NSRange(location: beforeLocation, length: beforeLength))?.string ?? ""

    // カーソル後 N 文字
    let totalLength = client.length()
    var after = ""
    if totalLength != NSNotFound, totalLength >= range.location + range.length {
        let afterLocation = range.location + range.length
        let afterLength = min(300, totalLength - afterLocation)
        after = client.attributedSubstring(
            from: NSRange(location: afterLocation, length: afterLength))?.string ?? ""
    }

    return (before, after)
}
```

`nil` / 空文字が返った場合は `committedHistory` ベースの文脈にフォールバックし、
IME としての通常の変換を継続する（LLM 文脈強化なしでも動作する）。

## 設計方針

### キャッシュ戦略

毎キー押下ごとに `attributedSubstring` を呼ぶと IPC コストが積算する。
変換開始タイミング（`composedHiragana` が空 → 1文字目入力）と
Space 押下（変換候補表示）の2点でのみ取得してキャッシュする。

```swift
// InputController に追加
private var cachedSurroundingContext: (location: Int, text: (before: String, after: String))?
```

**カーソル移動によるキャッシュ無効化**: `selectedRange().location` をキャッシュキーとして保持し、
次の取得時に変わっていればキャッシュを破棄して再取得する。これにより、マウスや矢印キーで
カーソルを動かした場合でも Space 押下時には最新の文脈が届く（Space 取得が上書きするため）。

`sentenceTerminators` による `committedHistory.removeAll()` のタイミングでキャッシュもリセット。

### フォールバック優先順位

| 状況 | 使う文脈 |
|------|---------|
| `fetchSurroundingContext` が `nil` | `committedHistory.suffix(5)` のみ |
| 成功だが `before` が空（文頭・Electron 等）| `committedHistory.suffix(5)` のみ |
| 成功かつ `before` 非空 | `before` 末尾 300 字（`committedHistory` は使わない）|

`after` テキストは今フェーズでは使わない（新規入力中はカーソルが末尾のため空になりやすく
効果が低い。将来の編集中シナリオ向けに取得だけしておく）。

### LLM プロンプトへの統合とプロンプト長の管理

`LLMCandidateScorer.buildPrompt` と `LLMSuccessorFetcher` のプロンプト構築時に渡す
`contextPrefix` を以下の順で組み立てる。

```
[before の末尾 300 字]
```

`committedHistory` との結合は**しない**（`before` には確定語が既に含まれるため二重になる）。
`before` が空の場合のみ `committedHistory.suffix(5).joined()` を代替として使う。

これによりプロンプト長は既存より増えるが上限 300 字で管理する。

### プライバシー

`before` / `after` はオンデバイス LLM にのみ渡す（ネットワーク送信しない）。
パスワード欄等のセキュリティ上センシティブなテキストがある場合でも外部に出ない。
将来クラウド LLM オプションを追加する際は設定で本機能を無効化できるようにしておく。

## テスト方針

`fetchSurroundingContext` は `IMKTextInput` に準拠した小さなテストダブルで境界テストを書く。
モック実装は `selectedRange` / `length` / `attributedSubstring` の3メソッドのみでよく、
煩雑にはならない。

テストすべき境界ケース:

| ケース | 期待 |
|--------|------|
| `location == NSNotFound` | `nil` を返す |
| `location == 0`（文頭）| `before = ""` |
| `location < 300`（文頭付近）| `beforeLength = location` で正しく切り取る |
| `totalLength == NSNotFound` | `after = ""`（`before` は取れる） |
| `totalLength == location`（文末）| `after = ""` |
| 通常ケース（前後に十分テキスト）| 前後 300 字が取れる |

## ファイル変更範囲

| ファイル | 変更内容 |
|---------|---------|
| `InputController.swift` | `fetchSurroundingContext(from:)` 追加、`cachedSurroundingContext` キャッシュ管理（location キー付き）、プロンプト構築時に渡す文脈を切り替え |
| `LLMCandidateScorer.swift` | `buildPrompt` の `contextPrefix` を `before` テキスト優先に変更（`committedHistory` フォールバック）|
| `LLMSuccessorFetcher.swift` | `fetch(context:)` に `before` テキストを渡せるよう引数拡張 |
| `Tests/` | `fetchSurroundingContext` の境界テスト（テストダブル使用） |

## 実装順序

1. `fetchSurroundingContext(from:)` を実装し、`os_log` でログ出力して取得内容を確認
2. **キャッシュなし**で `LLMCandidateScorer` に配線し、スコアリングへの効果を確認
3. `location` キー付きキャッシュを追加して IPC コストを計測
4. `LLMSuccessorFetcher` にも展開
5. テストダブルで境界テストを追加

キャッシュなし段階で「取れているか・効果があるか」を先に検証し、問題の切り分けを容易にする。

## 期待効果

- Electron 系アプリ以外（テキストエディット、Pages、メール等）でカーソル前の段落・文書トーンが LLM に届く
- 「先週の会議で〜」「このプロジェクトは〜」のような話題の軸に沿った同音異義語選択精度が向上
- `committedHistory` では取れない「直前の文章（前の文）」の文脈が使えるようになる
