# keynaco ドメイン用語集

用語の定義・不変条件・他概念との関係を記述する。

---

## 入力モード

### ASCII モード
`InputHandler.isAsciiMode = true` の状態。キー入力をそのまま挿入する。IME としての処理をバイパス。  
**不変条件**: `static` フィールドのためアプリをまたいで共有される。テストの `setUp` でリセット必須。

*Tests: `Tests/InputHandlerAsciiTests.swift`*

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

*Tests: `Tests/InputHandlerCandidatesTests.swift`*

### historyEnd
候補リスト内の「固定候補 + 予測候補 + 履歴候補」セクションの末尾インデックス。
`historyEnd = fixedCount + predictCount + historyCount`。
これ未満の候補は Shift+Delete で履歴 DB から削除可能。これ以降は AzooKey 専用候補（削除不可）。

*Tests: `Tests/InputHandlerCandidatesTests.swift`*

### isExplicitlySelected
↑↓ キーでユーザーが能動的に候補を選んだかどうかのフラグ。  
**役割**: `true` のとき、文字キー入力で選択候補をまず確定してから新しい文字を処理する。`false` のときは文字入力しても候補を確定せず組成に追加する。Enter は `isExplicitlySelected` に関係なく `selectedText`（現在の視覚的選択）をそのまま確定する。

### autoShow
文字入力中に候補ウィンドウを自動表示するかどうか。履歴・辞書・予測候補（tri-gram + bi-gram）がすべて 0 件なら表示しない。

*Tests: `Tests/InputHandlerCandidatesTests.swift`*

### 候補優先順位
1. ひらがな / カタカナ（`fixedCount` 件）
2. 予測候補（trigram を優先し、重複を除いた bigram で常に補完。`prev2Output` × `lastCommittedOutput` で trigram を引き、trigram にない bigram 候補を後に連結。さらに `mostRecentContentWord` × 現読みで skip-bigram を引き、trigram・bigram にない候補を末尾に追加）
3. 履歴 exact → 履歴 prefix
4. AzooKey 辞書候補

---

## セグメントモード（SegmentMode）

### SegmentState / isSegmentMode
Space 押下時に AzooKey の変換結果をセグメント（文節）分割して遷移した状態。  
Shift+Tab / Shift+矢印でセグメント境界を 1 文字単位で調整できる。

*Tests: `Tests/InputHandlerSegmentTests.swift`*

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

**N-gram 候補の遅延表示と読みフィルタ**:
N-gram 由来の候補（tri-gram + bi-gram + skip-bigram）がある場合、`suggestSuccessors()` は
候補を `pendingSuccessorCandidates` に保存して `.dismiss`（候補ウィンドウを閉じる）を返す。
1打目が入力されたとき、`romajiToInitialKana` でそのキーの読み先頭候補かなを取得し、
DB を再クエリして一致する候補のみ `.show` する（読みが一致しなければモード解除）。  
格助詞 fallback のみ（N-gram なし、名詞末尾の場合）は従来通り即時表示する。

*Tests: `Tests/InputHandlerSuccessorTests.swift`*

### pendingSuccessorCandidates
Successor モードで N-gram 候補を1打目まで遅延表示するためのバッファ。  
**不変条件**: `suggestSuccessors()` が N-gram 候補を計算した際に設定され、1打目の入力時に
`romajiToInitialKana` で読み前方一致フィルタを行い `.show` して空になる。
読みが一致しない場合はモード解除して空になる。
`isSuccessorMode = false` になるすべての経路でクリアされる。

### successorFirstChar
Successor モード中の 1 打目をバッファリングするフィールド。  
**不変条件**: 1 打目が格助詞 fast-path（`particleRomajiMap`）に対応し、かつ直前確定語が `isNounLike`
を満たすときのみ格助詞絞り込みバッファとして使用。2 打目が格助詞サブセットにマッチしなければ 1 打目を
通常入力として流してからモード解除する。  
`pendingSuccessorCandidates` が非空の場合（N-gram 遅延表示中）は、格助詞 fast-path 非該当の 1 打目でも
`successorFirstChar` にバッファして N-gram 候補を表示する（2打目でマッチしなければ通常通り流す）。

---

## 学習・履歴

### lastCommittedOutput
直前に確定した変換結果。trigram の prev1 および bigram の prev として使う。

### prev2Output
2語前に確定した変換結果。trigram 候補の検索キー（prev2）として使う。

### DatabaseManager
変換履歴（`history`）・bi-gram（`bigram`）・tri-gram（`trigram`）・skip-bigram（`skip_bigram`）の **4 テーブル**を持つ SQLite ストア。  
`InputHandler` のイニシャライザで DI。テストは `inMemory: true`。  
**`clock` var** でエポック秒を注入可能（テスト用）。全 record/fetch で `nowEpoch()` を使うことで時系列が一貫する。

#### recordPrefixes
読みが **3 文字以上**のひらがなを確定するとき、len=2 から N-1 までの前方一致パターンも同時に `history` に記録する。  
例: 「おはよう」（4文字）を確定 → `おはよう`/`おはよ`/`おは` の3エントリを記録。  
「おは」と打つだけで「おはよう」が履歴候補に出るようになる。ASCII のみの読み（`github` など）は prefix 記録しない。

#### recency / 時間減衰
全 fetch SQL は `score = count / (1 + age_days / τ)` でソートする（τ = 30日）。  
古い高頻度語より直近の語が優先されやすくなり、今日のタスクに合った語が上位に出やすい。  
テストでは `db.clock = { fixedEpoch }` で時刻を固定して検証する。

#### committedHistory
直近に確定した変換出力のリスト。`mostRecentContentWord` および skip-bigram 記録で参照される。  
**不変条件**: 上限は **5 件**。6 件目が追加されると先頭がドロップされる。  
**注意**: `mostRecentContentWord` は `committedHistory` の末尾から助詞をスキップして最初の内容語を返す。履歴が 1 件以下（直前語のみ）または全て助詞の場合は `nil`。

*Tests: `Tests/SkipBigramTests.swift` — `testCommittedHistoryCapAt5`, `testMostRecentContentWordSkipsParticle`*

#### skip-bigram
助詞（`InputHandler.particles`）が直前に確定されたとき、`mostRecentContentWord`（直近の非助詞語）と現在の確定語のペアを `skip_bigram` テーブルに記録する。  
`今日 → を → 行く` `今日 → が → 走る` のように助詞でバラけたペアが「今日 → 行く/走る」として統合される。

*Tests: `Tests/InputHandlerHistoryTests.swift`, `Tests/DatabaseManagerTests.swift`, `Tests/SkipBigramTests.swift`*

---

## テキスト出力

### insertText
確定済みテキストをアプリに送る操作。これを呼んだ後は組成状態をクリアする。

### setMarkedText
未確定テキスト（下線付き）をアプリに送る操作。組成中は毎キー呼ばれる。  
**注意**: `insertText` の代わりに候補選択確定で使うと Electron 系アプリに半角スペースが挿入される。

### TextInputClient
`insertText` / `setMarkedText` を抽象化するプロトコル。本番は IMK クライアントラッパー、テストは `MockTextClient`。
