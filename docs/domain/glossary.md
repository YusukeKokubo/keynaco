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
候補リスト index 0 から始まる固定枠数（ひらがな・カタカナ）。初期選択行は `fixedCount` から始まるため、↑ キーで遡らないと見えない位置に置かれる。

### historyEnd
候補リスト内の「固定候補 + 予測候補 + 履歴候補」セクションの末尾インデックス。
`historyEnd = fixedCount + predictCount + historyCount`。
これ未満の候補は Shift+Delete で履歴 DB から削除可能。これ以降は AzooKey 専用候補（削除不可）。

### isExplicitlySelected
↑↓ キーでユーザーが能動的に候補を選んだかどうかのフラグ。  
**役割**: `false` のまま Enter を押すと先頭候補ではなく現在の組成テキストを確定する。

### autoShow
文字入力中に候補ウィンドウを自動表示するかどうか。履歴・辞書・予測候補（tri-gram + bi-gram）がすべて 0 件なら表示しない。

### 候補優先順位
1. ひらがな / カタカナ（`fixedCount` 件）
2. 予測候補（trigram を優先し、重複を除いた bigram で常に補完。`prev2Output` × `lastCommittedOutput` で trigram を引き、trigram にない bigram 候補を後に連結）
3. 履歴 exact → 履歴 prefix
4. AzooKey 辞書候補

---

## セグメントモード（SegmentMode）

### SegmentState / isSegmentMode
Space 押下時に AzooKey の変換結果をセグメント（文節）分割して遷移した状態。  
Shift+Tab / Shift+矢印でセグメント境界を 1 文字単位で調整できる。

---

## Successor モード（SuccessorMode）

### isSuccessorMode
確定直後に学習済みの後続語候補を自動表示する状態。  
候補は `fetchTrigramTop(prev2:prev1:)` + `fetchBigramTop(prev:)` の組み合わせで引く。
2語前文脈（trigram）を優先し、trigram にない候補を bigram で補完する。  
漢字・カタカナ末尾（`isNounLike`）のときのみ、固定格助詞リスト（`InputHandler.particles`）を
tail に fallback として並べる。ひらがな末尾の語では格助詞 fallback は出さず、予測候補のみ表示する。
確定後は `suggestSuccessors()` を再呼び出しし、次の bi-gram / tri-gram 候補があれば
連鎖表示を継続する（格助詞チェックは廃止。候補空なら自然に `.dismiss`）。

### successorFirstChar
Successor モード中の 1 打目をバッファリングするフィールド。  
**不変条件**: 1 打目が格助詞 fast-path（`particleRomajiMap`）に対応し、かつ直前確定語が `isNounLike`
を満たすときのみバッファリング。2 打目が格助詞サブセットにマッチしなければ 1 打目を通常入力として
流してからモード解除する。非名詞末尾では fast-path を使わず即座に通常組成へフォールスルー。

---

## 学習・履歴

### lastCommittedOutput
直前に確定した変換結果。trigram の prev1 および bigram の prev として使う。

### prev2Output
2語前に確定した変換結果。trigram 候補の検索キー（prev2）として使う。

### DatabaseManager
変換履歴（`history`）・bi-gram（`bigram`）・tri-gram（`trigram`）の 3 テーブルを持つ SQLite ストア。  
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
