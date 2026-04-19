# keynaco ドメイン用語集

用語の定義・不変条件・他概念との関係を記述する。

---

## 入力モード

### ASCII モード
`InputHandler.isAsciiMode = true` の状態。キー入力をそのまま挿入する。IME としての処理をバイパス。  
**不変条件**: `static` フィールドのためアプリをまたいで共有される。テストの `setUp` でリセット必須。

### 日本語モード
`isAsciiMode = false`。ローマ字入力をひらがなに変換し、変換候補を提示する。

---

## 組成（Composition）

### composedHiragana
確定済みのひらがな文字列。ローマ字変換ルールで決まった文字が蓄積される。

### pendingRomaji
まだひらがなに確定していないローマ字断片。例: `k`（`ka` で `か` に確定）。

### CompositionState
`composedHiragana + pendingRomaji` の組み合わせ。未確定文字列全体を表す。  
**不変条件**: どちらかが非空なら「組成中」状態。両方が空なら「待機」状態。

### 組成テキスト（markedText）
アプリに送る下線付きの未確定文字列。`composedHiragana + pendingRomaji` を連結した表示用文字列。  
**注意**: 空文字を渡すと Electron 系アプリが IME を非アクティブと誤認する。

---

## 変換候補（Candidates）

### fixedCount
候補リスト先頭の固定枠数（ひらがな・カタカナ）。スクロールアウトしない。

### historyEnd
履歴セクションの末尾インデックス。これより前が「履歴候補」、以降が「辞書候補」。

### isExplicitlySelected
↑↓ キーでユーザーが能動的に候補を選んだかどうかのフラグ。  
**役割**: `false` のまま Enter を押すと先頭候補ではなく現在の組成テキストを確定する。

### autoShow
文字入力中に候補ウィンドウを自動表示するかどうか。履歴・辞書・bi-gram がすべて 0 件なら表示しない。

### 候補優先順位
1. ひらがな / カタカナ（`fixedCount` 件）
2. bi-gram 候補（`lastCommittedOutput` × 現在の読み）
3. 履歴 exact → 履歴 prefix
4. AzooKey 辞書候補

---

## セグメントモード（SegmentMode）

### SegmentState / isSegmentMode
Space 押下時に AzooKey の変換結果をセグメント（文節）分割して遷移した状態。  
Shift+Tab / Shift+矢印でセグメント境界を 1 文字単位で調整できる。

---

## 格助詞モード（ParticleMode）

### isParticleMode
確定直後に漢字・カタカナ末尾の語であることを検出し、格助詞候補を自動表示する状態。

### particleFirstChar
格助詞の頭文字 1 打目をバッファリングするフィールド。  
**不変条件**: 2 打目が格助詞に対応しなければ 1 打目を通常入力として流してからモード解除。

---

## 学習・履歴

### lastCommittedOutput
直前に確定した変換結果。bi-gram 候補の検索キーとして使う。

### DatabaseManager
変換履歴（`history`）と bi-gram（`bigram`）の 2 テーブルを持つ SQLite ストア。  
`InputHandler` のイニシャライザで DI。テストは `inMemory: true`。

---

## テキスト出力

### insertText
確定済みテキストをアプリに送る操作。これを呼んだ後は組成状態をクリアする。

### setMarkedText
未確定テキスト（下線付き）をアプリに送る操作。組成中は毎キー呼ばれる。  
**注意**: `insertText` の代わりに候補選択確定で使うと Electron 系アプリに半角スペースが挿入される。

### TextInputClient
`insertText` / `setMarkedText` を抽象化するプロトコル。本番は IMK クライアントラッパー、テストは `MockTextClient`。
