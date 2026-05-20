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

### hiddenPendingN
`nn`（連続 `n`）直後、内部的には `composedHiragana` に「ん」＋ pending `"n"` だが、**表示**と**確定**（`finalizedText`）では pending の `n` を使わない（「ん」1文字）ためのフラグ。  
Space や句読点の前に pending を `composedHiragana` へ取り込む処理（`absorbPendingIntoComposed`）でも同じく、hidden 時は pending を捨てる。

### 組成テキスト（markedText）
アプリに送る下線付きの未確定文字列。`composedHiragana + pendingRomaji` を連結した表示用文字列。  
**注意**: 空文字を渡すと Electron 系アプリが IME を非アクティブと誤認する。

---

## 変換候補（Candidates）

### fixedEnd
候補リスト先頭の固定枠（カナ固定 + ユーザー辞書 + Zenzai top-1）の末尾インデックス（末尾+1）。  
`fixedEnd` 未満の行は Shift+Delete 削除不可（ユーザー辞書・プロモート行を誤削除から保護）。

### historyEnd
「カナ固定〜高スコア履歴候補」セクションの末尾インデックス。  
`fixedEnd <= index < historyEnd` の行のみ Shift+Delete で履歴 DB から削除可能。  
閾値未満の低スコア履歴は数値・日時・AzooKey の後に続くためこの範囲外になる。

*Tests: `Tests/InputHandlerCandidatesTests.swift`*

### isExplicitlySelected
↑↓ キーでユーザーが能動的に候補を選んだかどうかのフラグ。  
**役割**: `true` のとき、文字キー入力で選択候補をまず確定してから新しい文字を処理する。`false` のときは文字入力しても候補を確定せず組成に追加する。Enter は `isExplicitlySelected` に関係なく `selectedText`（現在の視覚的選択）をそのまま確定する。

### autoShow
文字入力中に候補ウィンドウを自動表示するかどうか。履歴・AzooKey 辞書候補・予測候補・ユーザー辞書候補・日時候補がすべて 0 件なら表示しない。

*Tests: `Tests/InputHandlerCandidatesTests.swift`*

### particles
格助詞の固定リスト（`InputHandler.particles`）。Successor モードの名詞末尾 fallback、LLM 例示のフィルタ（`applySuccessorLLMScheduling`）等に使用する。

### hiraganaPreferred
ひらがな表記が自然な語彙の集合。`particles` の上位集合。  
**役割**: この集合に含まれる読みのとき、履歴スコア・予測候補の有無に関わらず `initialRow` をひらがな行にする（`assembleCandidateList`）。

*Tests: `Core/Sources/CoreTests/InputHandlerCandidatesTests.swift`*

### F4（誤変換検出）
確定直後（`insertText`）、カーソル直前最大 200 文字をオンデバイス LLM で検査するオプション機能。前文が 5 文字未満ならスキップ。0.5 秒デバウンス後に起動。  
**メニューバー**: 指摘あり時はタイトルを `⌨?` にし、左クリックでポップオーバーに全文を表示。  
**不変条件**: 次の通常組成が始まると通知でポップオーバーを閉じステータスをクリア。入力ソースの非アクティブ化（`activateServer`）でもキャンセル。

### 候補優先順位
1. ひらがな / カタカナ（固定枠）
2. ユーザー辞書（完全一致 + 前方一致）
3. **Zenzai top-1**（Zenzai 設定 ON かつ左文脈ありのときのみ）
4. 予測候補（noun-bigram。`lastConfirmedNounOutput` が必要）
5. 履歴（時間減衰スコアが閾値以上の行。完全一致読みのみ上位グループ）
6. 数字候補（数字のみ読みのとき）
7. 日時候補（`きょう` / `いま` 等のとき）
8. AzooKey 辞書候補（Zenzai プロモート済みは除外）
9. 低スコア履歴（閾値未満の履歴を末尾に）

### 括弧モード（isBracketMode）
`[` / `(` / `!` / `?` / `/` / `.` / `,` 等の記号キーを**待機中**（組成空）に入力したとき、対応する全角候補リストを候補ウィンドウで表示するモード（`bracketCandidates != nil`）。  
US キーボードの `Shift+/`（`?`）と `Shift+1`（`!`）は `baseCharacters` で判定し bracketOptions を発動する。  
**組成中**に記号キーを入力した場合は候補ウィンドウは表示せず、全角1文字目を `composedHiragana` に追加して通常の組成継続。

---

## セグメントモード（SegmentMode）

### SegmentState / isSegmentMode
Space 押下時に AzooKey の変換結果をセグメント（文節）分割して遷移した状態。  
Shift+矢印でセグメント境界を 1 文字単位で調整できる。

*Tests: `Tests/InputHandlerSegmentTests.swift`*

### SegmentState.llmWholeText（セグメント LLM 全文候補）
読み全体をオンデバイス LLM で一括変換した全文テキスト。`inferSegmentBoundaries` が成功した場合は各文節の候補先頭にその文節の LLM トークンが入り、連結がこの文字列になる。失敗時のフォールバックでは先頭文節のみに全文を挿入する。  
**短絡確定**: `focusedIndex == 0` かつ確定条件を満たすとき Enter で全文節を破棄し `llmWholeText` だけを確定する（詳細: `isLlmWholeTextShortcut`）。`inferSegmentBoundaries` が 2 ペア以上で成功した確定では境界を `boundary_pref` にも保存する。

### LLMSegmentConverter
セグメントモード用の FoundationModels ラッパー。`SystemLanguageModel.default` が利用可能なときのみ推論を走らせる。失敗時は空文字でコールバックし既存 UX を壊さない。

*Tests: `Tests/InputHandlerSegmentLLMTests.swift`、`Tests/SegmentBoundaryTests.swift`*

### boundary_pref（境界学習）
手動調整した境界、または LLM 多文節境界推定が成功した確定の読み分割を保存するテーブルエントリ。  
次回同じ読みで Space を押すと AzooKey の初期分割より保存済み境界が優先される（前方一致で最長キーを採用）。  
**保存条件**: 手動境界調整ありの確定、または `isLlmBoundaryInferred`（2ペア以上再構築）のとき。AzooKey 初期分割のままかつ LLM 条件も満たさない確定では保存しない。  
**上書きポリシー**: 同じ読みに対して再調整・確定すると前回エントリが上書きされる。GC: 180日未使用で削除。

---

## Successor モード（SuccessorMode）

### isSuccessorMode
確定直後に学習済みの後続語候補を `pendingSuccessorCandidates` に保持し、ユーザーの 1 打目で候補ウィンドウを開く状態。  
**起動条件**: 漢字・カタカナ末尾（`isNounLike` 真）のときのみ起動。ひらがな末尾（動詞・助詞・副詞等）の後は bi-gram があっても起動しない。  
noun-bigram で候補を取得し、格助詞リストを fallback として末尾に並べる。  
確定後は次の候補があれば連鎖表示を継続する（ただし確定語が名詞末尾の場合のみ）。

*Tests: `Tests/InputHandlerSuccessorTests.swift`、`Tests/LLMSuccessorFetcherTests.swift`*

### pendingSuccessorCandidates
Successor モードで候補を 1 打目まで遅延表示するためのバッファ（N-gram 予測語と格助詞 fallback）。  
1 打目でかな先頭一致フィルタを行い一致候補を表示。一致なしはモード解除。`isSuccessorMode = false` になるすべての経路でクリアされる。

### successorLLMSurfaceExtras
オンデバイス LLM が返した表層形の後続語候補。1 打目表示時に `pendingSuccessorCandidates` 由来の候補末尾に連結する。

### Successor prefix 展開（`expandSuccessorPrefixes`）
1 打目の候補マージ後、長い表層形を `InputHandler.particles` の助詞境界で prefix に分割して挿入する（形態素解析は使わない）。  
**不変条件**: 元の全体候補は各親の直後に必ず残す。助詞単独 prefix は出さない。体言で終わる prefix を助詞末尾より先に並べる。同一親からの prefix は最大 2 個。表示全体は `successorMaxCandidates`（5）を超えない。先頭が助詞の表層は分割しない。

*Tests: `Tests/InputHandlerSuccessorPrefixTests.swift`*

### successorFirstChar
Successor モード中の 1 打目をバッファリングするフィールド。2 打目がマッチしなければ 1 打目を通常入力として流してからモード解除する。

---

## 学習・履歴

### lastCommittedOutput
直前に確定した変換結果（`committedHistory.last`）。Successor の格助詞 fallback 判定等に使う。  
`committedHistory` が空のときは `virtualHistoryPrefix.last` でフォールバックする（**予測のみ**。学習は `committedHistory` 直参照）。

### virtualHistoryPrefix
IMK `before` テキスト末尾から抽出した仮想末尾語列（最大 2 語、古→新）。組成開始時に `InputController` がセットする。  
**不変条件**: `pushCommitted` / `successorLLMContext` には流さない。`UserDefaults` の `virtualHistoryEnabled`（デフォルト true）で無効化可能。

### lastConfirmedContext
確定直後の Backspace を「誤変換の訂正」として扱うために保持する直前 1 件の学習キー。  
**不変条件**: Backspace 以外のキー入力・ペナルティ実行後は `nil`。

### DatabaseManager
変換履歴（`history`）・noun-bigram（`noun_bigram`）・ユーザー辞書（`user_dict`）・境界学習（`boundary_pref`）・ひらがな優先語彙（`hiragana_preferred`）の **5 テーブル**を持つ SQLite ストア。  
`InputHandler` のイニシャライザで DI。テストは `inMemory: true`。起動時に廃止した `bigram` / `trigram` / `skip_bigram` を DROP する。  
全 fetch/record で時間減衰スコア `count / (1 + age_days / τ)`（τ=30日）を使用。`user_dict` のみ time-decay なし。

#### recordPrefixes
3 文字以上のひらがな確定時、len=2〜N-1 の前方一致パターンも同時に `history` に記録する。  
「おはよう」を確定すると「おはよ」「おは」でも履歴候補に出るようになる。  
ひらがなパススルー確定・句読点確定はスキップ。

#### noun-bigram
名詞→名詞のペアのみを `noun_bigram` に記録する。`prev` は直前に確定した名詞（助詞・動詞が間にあってよい）。  
確定時に `lastConfirmedNounOutput` をキャプチャし、LLM 品詞分類（`LLMPOSClassifier`）完了後 `pos == "noun"` のとき `recordNounBigram` する。  
Apple Intelligence 必須前提。無効時は noun-bigram は蓄積されず予測候補も出ない。

#### lastConfirmedNounOutput
LLM 品詞分類で最後に名詞と判定された確定語の表層。noun-bigram の `prev` および Successor / pending 先読みの参照キー。セッションをまたいでリセットしない。

#### penalizeAll（訂正シグナル）
確定直後 Backspace 時に呼ばれ、history の該当行を count -1（0以下で削除）、`boundary_pref` 行を DELETE する。

*Tests: `Tests/InputHandlerHistoryTests.swift`, `Tests/DatabaseManagerTests.swift`, `Tests/NounBigramTests.swift`*

---

## テキスト出力

### insertText
確定済みテキストをアプリに送る操作。これを呼んだ後は組成状態をクリアする。

### setMarkedText
未確定テキスト（下線付き）をアプリに送る操作。組成中は毎キー呼ばれる。  
**注意**: `insertText` の代わりに候補選択確定で使うと Electron 系アプリに半角スペースが挿入される。

### TextInputClient
`insertText` / `setMarkedText` を抽象化するプロトコル。本番は IMK クライアントラッパー、テストは `MockTextClient`。
