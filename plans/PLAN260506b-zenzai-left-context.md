# PLAN260506b: Zenzai 左文脈の品質向上

## 背景・問題

Zenzai はニューラル LM であり、左文脈（`leftSideContext`）が長く正確なほど変換精度が上がる。

現在の `resolvedLLMDocumentContextPrefix()` は以下のロジックで動く：

```
SurroundingIMKContext.before (最大 300 字)  ← キャッシュ有効時
      ↓ 取得できない場合のフォールバック
committedHistory.suffix(5).joined()
```

問題は、**`before` が取得できた場合に `committedHistory` が完全に無視される**点。
`before` は IMK クライアント（アプリ側）が提供するため、アプリ依存のばらつきがある：

| アプリ | 状況 |
|--------|------|
| Safari / TextEdit | `before` にカーソル前の全文が入る（`committedHistory` の内容も含む）|
| Electron 系アプリ | `before` が空や 0 文字になるケースがある |
| ターミナル / 特殊アプリ | `before` が不完全（最新の確定語が含まれないことがある）|

結果として、Electron 系や特定アプリで Zenzai が「直前に何を入力したか」を把握できず、
文脈なしの汎用変換になってしまう。

## 目標

あらゆるアプリで Zenzai に**最良の左文脈**を渡す。
`committedHistory` はアプリ非依存でキーナコ自身が持つ確実な情報であり、
これを `before` と組み合わせることで品質を底上げする。

## 設計

### 現状の構造（変更前）

```swift
// InputController.swift:442
private func resolvedLLMDocumentContextPrefix(adapter: IMKTextInputAdapter) -> String {
    let historyJoined = handler.committedHistory.suffix(5).joined()
    let loc = adapter.selectedRange().location
    guard loc != NSNotFound else { return historyJoined }

    if let cache = cachedSurroundingContext, cache.location == loc, !cache.text.before.isEmpty {
        let b = cache.text.before
        return b.count > 300 ? String(b.suffix(300)) : b  // ← committedHistory を捨てている
    }
    // ...
    return historyJoined
}
```

### 捨てた案：長さ比較（`before.count` vs `historyJoined.count`）

第一案では「`before` の方が `historyJoined` より短いときだけ結合」としていたが、**捨てる**。

意図は「アプリが surrounding に最新の確定語を反映していないとき補完」だが、長さ比較はそれを表さない。

- **偽陰性の例**: `historyJoined = "東京"`（短い）、`before = "今日は会議の件で"`（長いが「東京」を含まない）→ 長い方が `before` なので「ケース C」扱いとなり `before` のみ → 補完が必要なのに行われない。
- **本質的に知りたいのは**「`before` が `committedHistory` の内容を含むか」であり、**どちらが長いか**ではない。

補足として検討した **案（最後の確定語が `before` に含まれるか）** は、部分一致 `contains` による短い語の誤検知リスクがあり、分岐を増やす割にメリットが限定的。

### 採用方針：常に先頭に `historyJoined` を付与（案 B）

`before` がキャッシュで非空のとき:

- `historyJoined` が**非空**なら、常に `historyJoined + beforeTruncated` を返す（順序は確定履歴が先、ドキュメント前文が後）。
- `historyJoined` が空なら `beforeTruncated` のみ（従来どおり `before` 側の意味）。

`before` が空のときは従来どおり `historyJoined` のみ（変更なし）。

**重複について**: Safari 等で `before` が既に確定語を含む場合、先頭に `historyJoined` を再度付けると同一フレーズが連続する。ただし `committedHistory` は最大 5 語・実用上おおむね数十文字に収まり、重複は短い。ニューラル LM に与える害は軽微で、**分岐なしで挙動が予測可能**なことの方が優先。

### 結合後の文字数上限（履歴を先に確保）

- `before` 単体は従来どおり最大 **300 字**（`suffix(300)`）。
- 結合後の総長は最大 **400 字**。ただし **`(historyJoined + beforeTruncated).suffix(400)` のような切り方はしない**。末尾側を優先すると左から落ち、`historyJoined` 自体が切り捨てられ「履歴を足す変更が無効化」されるため。

**採用する切り方**: `historyJoined` が非空のときは常に先頭に**全量**残し、残り `400 - historyJoined.count` 字を `beforeTruncated` が埋める。`before` が長い場合は `beforeTruncated` の**右端**（カーソルに近い側）を `suffix(maxBefore)` で採用する。（`historyJoined` 単体が 400 字を超えるケースは最大 5 語のため実質発生しない想定。）

根拠: 単一ソース時代の「左文脈 ~300 字」というコスト感を維持しつつ、先頭に付く `historyJoined` 分のバッファを足した値。**Zenzai のモデル自体のコンテキストウィンドウはもっと大きいが、左文脈はコスト・レイテンシに効くため現状の 300 字上限と同様、実装上のキャップとして 400 を採用**（必要なら後から AzooKey / 計測に合わせて調整）。

### 変更後のコード（概要）

```swift
private func resolvedLLMDocumentContextPrefix(adapter: IMKTextInputAdapter) -> String {
    let historyJoined = handler.committedHistory.suffix(5).joined()
    let loc = adapter.selectedRange().location
    guard loc != NSNotFound else { return historyJoined }

    if let cache = cachedSurroundingContext, cache.location == loc, !cache.text.before.isEmpty {
        let rawBefore = cache.text.before
        let beforeTruncated =
            rawBefore.count > 300 ? String(rawBefore.suffix(300)) : rawBefore
        if !historyJoined.isEmpty {
            let maxBefore = max(0, 400 - historyJoined.count)
            let trimmedBefore =
                beforeTruncated.count > maxBefore
                ? String(beforeTruncated.suffix(maxBefore))
                : beforeTruncated
            return historyJoined + trimmedBefore
        }
        return beforeTruncated
    }

    if cachedSurroundingContext != nil { cachedSurroundingContext = nil }
    return historyJoined
}
```

実装時は関数直上のドキュメントコメント（現状「before なら最大 300 字のみ」）を、結合ロジックに合わせて更新する。

### キャッシュへの影響

`azooKeyLeftContext`（`leftSideContext` が空なら nil）がキャッシュキーの一部になっている。
左文脈が変わればキャッシュは自動的に外れるため、追加の変更は不要。

## 変更ファイル

| ファイル | 変更内容 |
|---------|---------|
| `keynaco/InputController.swift` | `resolvedLLMDocumentContextPrefix()` の結合ロジック + コメント更新 |

`InputController` は IMK 依存のため単体テストは対象外（変更なし）。

## 検証方法

1. `/deploy` でビルド・インストール
2. `/keynaco-ime-sandbox` スキルで動作確認

**確認シナリオ**：
- 「東京」「で」確定後に「開催」と入力 → Zenzai が「開催される」「開催された」等を候補先頭に昇格するか
- Electron 系アプリ（例: VS Code のターミナル入力欄）で連続入力時の変換精度
- Safari / TextEdit での連続入力（`historyJoined` と `before` の短い重複があっても変換が破綻しないか）

## 実装手順

1. `InputController.swift` の `resolvedLLMDocumentContextPrefix()` とそのドキュメントコメントを修正
2. ビルド確認（`xcodebuild build -scheme keynaco -configuration Debug`）
3. サンドボックスおよび必要なら実アプリで連続入力シナリオを試験
4. 問題なければコミット・PR

## 実装記録

- **実装日**: 2026-05-06
- **変更**: [`keynaco/InputController.swift`](../keynaco/InputController.swift) の `resolvedLLMDocumentContextPrefix(adapter:)` — `before` がキャッシュで非空かつ `committedHistory.suffix(5).joined()` が非空のとき、`historyJoined` を切らず先頭に結合し、`before` は 300 字に切った後、結合総長が 400 字を超えないよう `before` 側のみ `suffix(maxBefore)` でトリム。直上のドキュメントコメントを同期更新。
- **ビルド**: `xcodebuild build -scheme keynaco -configuration Debug` 成功（実装時点）。
- **手動検証**: 未実施（サンドボックス・実アプリは [検証方法](#検証方法) を参照）。
