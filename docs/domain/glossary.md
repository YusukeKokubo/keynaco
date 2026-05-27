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

*Tests: `Tests/InputHandlerCandidatesTests.swift`*

### isExplicitlySelected
↑↓ キーでユーザーが能動的に候補を選んだかどうかのフラグ。  
**役割**: `true` のとき、文字キー入力で選択候補をまず確定してから新しい文字を処理する。`false` のときは文字入力しても候補を確定せず組成に追加する。Enter は `isExplicitlySelected` に関係なく `selectedText`（現在の視覚的選択）をそのまま確定する。

### autoShow
文字入力中に候補ウィンドウを自動表示するかどうか。履歴・AzooKey 辞書候補・予測候補・ユーザー辞書候補・日時候補がすべて 0 件なら表示しない。

*Tests: `Tests/InputHandlerCandidatesTests.swift`*

### hiraganaPreferred
ひらがな表記が自然な語彙の集合（DB `hiragana_preferred` テーブルから読み込み）。  
**役割**: この集合に含まれる読みのとき、履歴スコア・予測候補の有無に関わらず `initialRow` をひらがな行にする（`assembleCandidateList`）。

*Tests: `Core/Sources/CoreTests/InputHandlerCandidatesTests.swift`*

### 候補優先順位
1. ひらがな / カタカナ（固定枠）
2. ユーザー辞書（完全一致 + 前方一致）
3. **Zenzai top-1**（Zenzai 設定 ON かつ左文脈ありのときのみ）
4. 履歴（時間減衰スコアが閾値以上の行。完全一致読みのみ上位グループ）
5. 数字候補（数字のみ読みのとき）
6. 日時候補（`きょう` / `いま` 等のとき）
7. AzooKey 辞書候補（Zenzai プロモート済みは除外）

（旧）予測候補（content_bigram）は 2026-05-25 に削除。

### sessionTextBuffer
Zenzai 左文脈用のインメモリバッファ（上限 50 字）。`commitText` で確定語を追記し、文末 `。` でもリセットしない。ASCII Enter・組成なし Enter・アプリ切替でクリア。`resolvedLLMDocumentContextPrefix` の素材（[`plans/PLAN260525.md`](../../plans/PLAN260525.md) 参照）。

*Tests: `Core/Sources/CoreTests/InputHandlerHistoryTests.swift`, `ZenzaiLeftContextTests.swift`*

### 括弧モード（isBracketMode）
`[` / `(` / `!` / `?` / `/` / `.` / `,` / `@` / `#` 等の記号キーを**待機中**（組成空）に入力したとき、対応する全角候補リストを候補ウィンドウで表示するモード（`bracketCandidates != nil`）。  
US キーボードの `Shift+/`（`?`）と `Shift+1`（`!`）は `baseCharacters` で判定し bracketOptions を発動する。  
**組成中**に記号キーを入力した場合は候補ウィンドウは表示せず、全角1文字目を `composedHiragana` に追加して通常の組成継続。

---

## セグメントモード（SegmentMode）

### SegmentState / isSegmentMode
Space 押下時に AzooKey の変換結果をセグメント（文節）分割して遷移した状態。  
Shift+矢印でセグメント境界を 1 文字単位で調整できる。

*Tests: `Tests/InputHandlerSegmentTests.swift`*

---

## 学習・履歴

### lastCommittedOutput
直前に確定した変換結果（`committedHistory.last`）。content-bigram の prev 参照等に使う。

### lastConfirmedContext
確定直後の Backspace を「誤変換の訂正」として扱うために保持する直前 1 件の学習キー。  
**不変条件**: Backspace 以外のキー入力・ペナルティ実行後は `nil`。

### DatabaseManager
変換履歴（`history`）・ユーザー辞書（`user_dict`）・ひらがな優先語彙（`hiragana_preferred`）・日次確定ログ（`daily_log`）・生成済み日記キャッシュ（`diary`）の **5 テーブル**を持つ SQLite ストア。  
`InputHandler` のイニシャライザで DI。テストは `inMemory: true`。起動時に廃止した `bigram` / `trigram` / `skip_bigram` / `boundary_pref` / `noun_bigram` / `content_bigram` を DROP する（マイグレーション用）。  
全 fetch/record で時間減衰スコア `count / (1 + age_days / τ)`（τ=30日）を使用。`user_dict` のみ time-decay なし。

#### recordPrefixes
3 文字以上のひらがな確定時、len=2〜N-1 の前方一致パターンも同時に `history` に記録する。  
「おはよう」を確定すると「おはよ」「おは」でも履歴候補に出るようになる。  
ひらがなパススルー確定・句読点確定はスキップ。

#### penalizeAll（訂正シグナル）
確定直後 Backspace 時に呼ばれ、history の該当行を count -1（0以下で削除）する。

*Tests: `Tests/InputHandlerHistoryTests.swift`, `Tests/DatabaseManagerTests.swift`*

---

## テキスト出力

### insertText
確定済みテキストをアプリに送る操作。これを呼んだ後は組成状態をクリアする。

### setMarkedText
未確定テキスト（下線付き）をアプリに送る操作。組成中は毎キー呼ばれる。  
**注意**: `insertText` の代わりに候補選択確定で使うと Electron 系アプリに半角スペースが挿入される。

### TextInputClient
`insertText` / `setMarkedText` を抽象化するプロトコル。本番は IMK クライアントラッパー、テストは `MockTextClient`。
