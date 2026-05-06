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

### fixedEnd
カナ固定 + ユーザー辞書 +（条件付き）**Zenzai top-1 プロモート 1 行**の直後のインデックス（末尾+1）。内部では `fixedCount + userDictCount` にプロモート行があれば +1 した値が `CandidateAction.fixedEnd` として返る。
`fixedEnd` 未満の行は Shift+Delete 削除不可（ユーザー辞書・プロモート行は誤削除から保護）。

### historyEnd
候補リスト内の「カナ固定 + ユーザー辞書 +（あれば）Zenzai top-1 + 予測候補 + **高スコア**履歴候補」セクションの末尾インデックス（時間減衰スコア `recencyExpr` が閾値 **未満**の履歴は含めない）。
`historyEnd = fixedEnd + predictCount + highHistoryCount`（この式の `fixedEnd` は `CandidateAction` に返すプロモート込みの値。`highHistoryCount` は閾値以上の履歴件数）。
`fixedEnd <= index < historyEnd` の行のみ Shift+Delete で履歴 DB から削除可能。
閾値未満の履歴は数値・日時・AzooKey の**後**に続くため、この範囲外になり Shift+Delete 不可（辞書候補と同様の扱い）。

*Tests: `Tests/InputHandlerCandidatesTests.swift`*

### isExplicitlySelected
↑↓ キーでユーザーが能動的に候補を選んだかどうかのフラグ。  
**役割**: `true` のとき、文字キー入力で選択候補をまず確定してから新しい文字を処理する。`false` のときは文字入力しても候補を確定せず組成に追加する。Enter は `isExplicitlySelected` に関係なく `selectedText`（現在の視覚的選択）をそのまま確定する。

### autoShow
文字入力中に候補ウィンドウを自動表示するかどうか。履歴・AzooKey 辞書候補・予測候補（tri-gram + bi-gram）・ユーザー辞書候補・日時候補がすべて 0 件なら表示しない。

*Tests: `Tests/InputHandlerCandidatesTests.swift`*

### F4（誤変換検出）
確定直後（`insertText`）、カーソル直前最大 200 文字をオンデバイス LLM で検査するオプション機能。前文が 5 文字未満ならスキップ。0.5 秒デバウンス後に起動。  
**メニューバー**: 指摘あり時はタイトルを `⌨?` にし、左クリックでポップオーバーに全文を表示（問題なし時・クリア時は通常の `⌨` または Successor 保留の `⌨…`）。  
**不変条件**: 次の通常組成（ひらがな入力）が始まると通知でポップオーバーを閉じステータスをクリア。入力ソースの非アクティブ化（`activateServer`）でもキャンセル。

### 候補優先順位
1. ひらがな / カタカナ（`fixedCount` 件）
2. ユーザー辞書（完全一致 + 前方一致）
3. **Zenzai top-1**（Zenzai 設定 ON かつ左文脈ありのときのみ、ユーザー辞書の直後に辞書先頭候補を 1 行。設定フラグはモデル未ロード時も true になり得る）
4. 予測候補（trigram を優先し、重複を除いた bigram で常に補完。`prev2Output` × `lastCommittedOutput` で trigram を引き、trigram にない bigram 候補を後に連結。さらに `mostRecentContentWords(n: 2)` の各語 × 現読みで skip-bigram を引き（近い内容語の結果を先）、`merged` で重複除去のうえ trigram・bigram にない候補を末尾に追加。辞書先頭と同じ表層は予測から除外）
5. 履歴（`fetchHistoryScoredMerged`：exact → prefix 重複除去。スコアが閾値**以上**の行のみこのブロックに置く。閾値**未満**は 8 の直前に回す）
6. 数字候補（`generateNumberCandidates`、数字のみ読みのとき。`historyEnd` 直後に挿入）
7. 日時候補（`きょう` / `いま` 等のとき。数字候補の直後に挿入）
8. AzooKey 辞書候補（プロモート済み先頭は除外）
9. 低スコア履歴（同じく `fetchHistoryScoredMerged` 由来。閾値未満の行を重複除外して末尾に追記）

### 括弧モード（isBracketMode）
`[` / `(` 等の括弧キーを**待機中**（組成空）に入力したとき、対応する全角括弧の候補ウィンドウを表示するモード（`bracketCandidates != nil`）。  
`handleBracketModeKey()` がキーを処理し、`bracketOptions` マップで ASCII 括弧 → 全角候補列に変換する（例: `[` → `「` / `【` / `〔` / ...）。  
**組成中**に括弧を入力した場合は候補ウィンドウは表示せず、全角1文字目を `composedHiragana` に追加して通常の組成継続。

---

## セグメントモード（SegmentMode）

### SegmentState / isSegmentMode
Space 押下時に AzooKey の変換結果をセグメント（文節）分割して遷移した状態。  
Shift+Tab / Shift+矢印でセグメント境界を 1 文字単位で調整できる。

*Tests: `Tests/InputHandlerSegmentTests.swift`*

### SegmentState.llmWholeText（セグメント LLM 全文候補）
読み全体（`composedHiragana`）をオンデバイス LLM で一括変換した全文テキスト。`inferSegmentBoundaries` が成功した場合は各文節の `candidates` 先頭にその文節の LLM トークンが入り、連結がこの文字列になる。失敗時のフォールバックでは先頭文節のみに全文を先頭挿入する。  
**不変条件（短絡確定）**: `doConfirmSegments` / `commitComposition` で LLM 全文のみ確定するのは `focusedIndex == 0` のうえ、**(A) 多文節再構築後**: 全文節が先頭行選択かつ各行先頭の連結が `llmWholeText` で、かつフォーカス文節の確定テキストがその文節の `candidates[0]` と一致するとき、または **(B) 旧フォールバック**: `segments[0].candidates[0] == llmWholeText` かつ先頭行選択で確定テキストが `llmWholeText` そのものとき。**`inferSegmentBoundaries` が 2 ペア以上を返して `applyLLMBoundaries` で多文節に再構築された場合**（`isLlmBoundaryInferred == true`）は、その読み境界を確定時に `boundary_pref` にも保存する（1 ペアのみの再構築・先頭文節への全文フォールバック挿入では保存しない）。確定時は全文節を破棄し `commitText(llmWholeText)` のみ行う。  
フォールバック挿入時は `segments[0].historyEnd` を 1 増やし、`segments[0].selectedIndex` は先頭挿入に合わせて 1 増やす（リフレッシュ前の視覚選択を維持）。

### LLMSegmentConverter
セグメントモード用の FoundationModels ラッパー。`SystemLanguageModel.default` が利用可能なときのみ `convert(hiragana:onResult:)` が推論を走らせる。失敗時は空文字でコールバックし既存 UX を壊さない。  
静的メソッド `inferSegmentBoundaries` は LLM 出力と読みのアライメントを試みる（辞書は `candidatesForSegment` のみ利用）。

*Tests: `Tests/InputHandlerSegmentLLMTests.swift`、`Tests/SegmentBoundaryTests.swift`*

### boundary_pref（境界学習）
手動調整した境界、または **LLM 多文節境界推定が成功した確定**の読み分割を保存する `boundary_pref` テーブルのエントリ。  
`enterSegmentMode()` は `azooKeyConverter.segmentize()` を呼ぶ前に `fetchBoundaryPref` を確認し、
ヒットすれば保存済み境界を優先して使う。ヒットしなければ AzooKey の初期分割にフォールバック。  
**取得の前方一致**: 完全一致だけでなく、入力のフル読みが保存キー（`full_reading`）で始まる行のうち、**最長の `full_reading`** を 1 件選んでその `boundaries` を使う（より長い読みへの入力でも、短いキーで学習した境界を再利用できる）。  
**保存の最短長**: `full_reading` の Swift `String.count` が 4 未満のときは `saveBoundaryPref` が保存しない（一律ガード）。  
**保存条件**: `doConfirmSegments()` 時に **`isManuallyAdjusted` なセグメントが 1 つ以上ある**、または **`SegmentState.isLlmBoundaryInferred` が真**（`inferSegmentBoundaries` が 2 ペア以上返し多文節に再構築済み）のとき記録する。AzooKey 初期分割のままかつ上記 LLM 条件も満たさない確定では記録しない。  
**上書きポリシー**: 同じ `full_reading` に対して再調整・確定すると前回エントリが上書きされる（`ON CONFLICT DO UPDATE`）。  
**GC**: 180日未使用のエントリを `performGCIfNeeded()` で削除する（`count` カラムなし、`used_at` のみで判定）。

---

## Successor モード（SuccessorMode）

### isSuccessorMode
確定直後に学習済みの後続語候補を自動表示する状態。  
候補は `fetchTrigramTop(prev2:prev1:)` + `fetchBigramTop(prev:)` + `mostRecentContentWords(n: 2)` ごとの `fetchSkipBigramTop`（`merged` で重複除去、近い内容語を優先）で引く。
2語前文脈（trigram）を優先し、trigram にない候補を bigram で補完する。  
漢字・カタカナ末尾（`isNounLike`）のときのみ、固定格助詞リスト（`InputHandler.particles`）を
tail に fallback として並べる。ひらがな末尾の語では格助詞 fallback は出さず、予測候補のみ表示する。
確定後は `suggestSuccessors()` を再呼び出しし、次の bi-gram / tri-gram 候補があれば
連鎖表示を継続する（格助詞チェックは廃止。候補空なら自然に `.dismiss`）。

**N-gram 候補の遅延表示と読みフィルタ**:
N-gram 由来の候補（tri-gram + bi-gram + skip-bigram）がある場合、`suggestSuccessors()` は
まず `fetchBigramTopCount(prev: last)` で前語に対する bi-gram 上位使用回数を取得する。
`successorImmediateThreshold`（デフォルト 5。`LearningThresholds.successorImmediateThreshold` と一致）以上なら「高信頼ペア」とみなして即時表示（`.show`）。なお `fetchBigramTopCount` は直近 **90 日以内**の bi-gram の `MAX(count)` を取るが、**プリセット行**（`is_preset = 1`）は `used_at` に関係なく常に集計に含まれる（閾値判定から外れない）。
閾値未満なら候補を `pendingSuccessorCandidates` に保存して `.dismiss` を返す（1打目待ち）。
1打目が入力されたとき、`romajiToInitialKana` でそのキーの読み先頭候補かなを取得し、
DB を再クエリして一致する候補に加え、**同一条件で** `pendingSuccessorCandidates` 内の語を読み前方一致で併合して `.show` する（DB 候補の後ろに追加。読みがいずれにも一致しなければモード解除）。  
格助詞 fallback のみ（N-gram なし、名詞末尾の場合）は従来通り即時表示する。

**オンデバイス LLM 補完**（`LLMSuccessorFetcher`、Foundation Models / Apple Intelligence 利用可能時のみ）:
N-gram あり・閾値未満（保留）の直後、または格助詞のみ即時表示の直後に、`committedHistory` の末尾最大3語（`"、"` 結合した文脈）を渡して続く語を非同期取得する。
返答は **表層形**（漢字・カタカナ・ひらがな）とし、別バッファ **`successorLLMSurfaceExtras`** に蓄える（`pendingSuccessorCandidates` には混ぜない。読み前方一致は N-gram 側のみ）。
保留（`.dismiss`）から1打目で候補を開くときは、DB 照会＋`mergePendingSuccessorMatches` の結果の **末尾**に `successorLLMSurfaceExtras` を重複除外で連結する。
格助詞のみ即時表示のときは、格助詞列を `successorLLMBaseCandidates` に保持し、LLM 語だけを `successorLLMSurfaceExtras` に足してウィンドウを更新する。
非同期コールバックは `Array(committedHistory.suffix(3))` がフェッチ開始時のスナップショットと一致するときだけ反映する。
LLM が1打目表示より遅れて届いた場合、**画面は更新しない**（extras にのみ溜まりうる仕様）。

*Tests: `Tests/InputHandlerSuccessorTests.swift`、`Tests/LLMSuccessorFetcherTests.swift`*

### pendingSuccessorCandidates
Successor モードで N-gram 候補を1打目まで遅延表示するためのバッファ（**学習由来の語のみ**。オンデバイス LLM の表層形は含めない）。  
**不変条件**: `suggestSuccessors()` が N-gram 候補を計算した際に設定され、1打目の入力時に
`romajiToInitialKana` で読み前方一致フィルタを行い（併せて本バッファ内の語を DB 結果と merge）、`.show` して空になる。
読みが一致しない場合はモード解除して空になる。
`isSuccessorMode = false` になるすべての経路でクリアされる。  
LLM 由来の語は `successorLLMSurfaceExtras` を参照する。

### successorLLMSurfaceExtras
オンデバイス LLM が返した **表層形**の後続語候補。`mergePendingSuccessorMatches` の `pending` には渡さない。
`suggestSuccessors()` が Successor に入るたびにクリアされ、補助状態クリア時にも空になる。

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

### lastConfirmedContext
確定直後の Backspace を「誤変換の訂正」として扱うために、`commitText` / `confirmSuccessor` が保持する直前 **1 件**の学習キー。`(input, output, prev1, prev2, skipPrevs, fullReading)`。`skipPrevs` は助詞直前確定時に記録した skip-bigram の `prev` 語の列（最大 2 語。格助詞のみ確定パスでは空配列）。  
**不変条件**: Backspace 以外のキー入力・ペナルティ実行後は `nil`。セグメント全読み確定時のみ `fullReading` が非 `nil`（`boundary_pref` 削除用）。

### DatabaseManager
変換履歴（`history`）・bi-gram（`bigram`）・tri-gram（`trigram`）・skip-bigram（`skip_bigram`）・ユーザー辞書（`user_dict`）・境界学習（`boundary_pref`）の **6 テーブル**を持つ SQLite ストア。  
`InputHandler` のイニシャライザで DI。テストは `inMemory: true`。  
**`clock` var** でエポック秒を注入可能（テスト用）。全 record/fetch で `nowEpoch()` を使うことで時系列が一貫する。

#### プリセット bi-gram（`is_preset`）
冷スタートでも後続予測が効くよう、アプリバンドル内の `preset_bigram.csv`（`prev,input,output`）から **初回起動時のみ**（`UserDefaults` の `preset_seeded_v1` が未セットのとき。保存先は `DatabaseManager.presetSeedUserDefaults`、既定は `standard`）`bigram` に投入する。各行は `is_preset = 1`・初期 `count = successorImmediateThreshold`・`INSERT OR IGNORE`（ユーザー既存行と衝突したら無視）。  
設定画面の Bi-gram **インポート**（`replaceBigram`）では `is_preset = 0` の行のみ全削除し、プリセット行は残す。**GC**（`performGCIfNeeded`）でもプリセット行は削除しない。ユーザーが `recordBigram` で同じ `(prev,input,output)` に学習した場合、`ON CONFLICT` で `count` / `used_at` のみ更新され、`is_preset` は変わらない。

**データ出典**: `Sources/PresetBigram/preset_bigram.csv` はリポジトリ内スクリプト `scripts/generate_preset_bigram_csv.py` で生成した汎用連語リストであり、**プロジェクトオリジナル（独自編集）**。第三者コーパスの転載ではない。

#### recordPrefixes
読みが **3 文字以上**のひらがなを確定するとき、len=2 から N-1 までの前方一致パターンも同時に `history` に記録する。  
例: 「おはよう」（4文字）を確定 → `おはよう`/`おはよ`/`おは` の3エントリを記録。  
「おは」と打つだけで「おはよう」が履歴候補に出るようになる。ASCII のみの読み（`github` など）は prefix 記録しない。

#### recency / 時間減衰
全 fetch SQL は `score = count / (1 + age_days / τ)` でソートする（τ = 30日）。  
古い高頻度語より直近の語が優先されやすくなり、今日のタスクに合った語が上位に出やすい。  
テストでは `db.clock = { fixedEpoch }` で時刻を固定して検証する。

#### committedHistory
直近に確定した変換出力のリスト。`mostRecentContentWord` / `mostRecentContentWords` および skip-bigram 記録で参照される。  
**不変条件**: 上限は **5 件**。6 件目が追加されると先頭がドロップされる。  
**注意**: `mostRecentContentWord()` は `mostRecentContentWords(n: 1).first` と同じ。`mostRecentContentWords(n:)` は末尾から 2 語目以降を遡り、助詞をスキップして最大 `n` 件の内容語を**近い順**に返す。履歴が 2 件未満、または内容語が 1 件もない場合は空配列（単一取得 API では `nil`）。

*Tests: `Tests/SkipBigramTests.swift` — `testCommittedHistoryCapAt5`, `testMostRecentContentWordSkipsParticle`*

#### skip-bigram
助詞（`InputHandler.particles`）が直前に確定されたとき、`mostRecentContentWords(n: 2)` が返す各内容語（最大 2 語）と現在の確定語のペアを `skip_bigram` テーブルに記録する（同一トランザクションで複数行になりうる）。  
`今日 → を → 行く` `今日 → が → 走る` のように助詞でバラけたペアが「今日 → 行く/走る」として統合される。

#### penalizeAll（訂正シグナル）
確定直後 Backspace 時に呼ばれる。`history` の該当行を count -1（0 以下で削除）、同じ確定に対応する `bigram`（**`is_preset = 0` のみ**）/`trigram`/`skip_bigram` も同様に -1、`fullReading` があればそのキーの `boundary_pref` 行を DELETE。`withTransaction` で一括実行。

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
