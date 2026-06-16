# Changelog

macOS IME **keynaco** の機能追加・変更・修正のログ。日付降順。

---

## 2026-06-16 — hiddenPendingN 削除

実装: `191edff` / ドキュメント: `2a809d3`

### 削除
- **`hiddenPendingN`** — `nn` 後の非表示 pending `n` と `CompositionState.hiddenPendingN` フラグ。`hiddenNKeepFollowers`・Enter 時 hidden 分岐・`InputHandlerHiddenPendingNTests` を含む

### 変更
- **`RomajiConverter`** — `nn` を両方消費して `ん` に確定（ローマ字テーブル通り）。例: `konnyaku` → こんやく
- **`docs/rejected.md`** — R-1（`hiddenPendingN` 不採用）を追記

---

## 2026-05-25 — sessionTextBuffer・content_bigram 廃止

設計: [`plans/POC260525-left-context-enhancement.md`](plans/POC260525-left-context-enhancement.md) / 実装: [`plans/PLAN260525-session-text-buffer.md`](plans/PLAN260525-session-text-buffer.md)（`5edf2bc` → `86c163a`）

### 追加
- **sessionTextBuffer** — Zenzai 左文脈用インメモリバッファ（上限 50 字・文末 `。` でもリセットしない）。`resolvedLLMDocumentContextPrefix` の素材を `committedHistory.suffix(5)` から差し替え（`861bd8b`, `b66232e`）
- **HiraganaPreferredBuiltins** — 組み込み固定語・LLM スキップ語を Core に集約（`5edf2bc`）

### 削除
- **content_bigram** — 実データで `count >= 2` を満たす行がなく予測に寄与しないため DB・候補・POSCommitSequencer 経路を削除（`5edf2bc`）
- **POSCommitSequencer** — POS 分類は `LLMPOSClassifier.enqueue` 直呼びに簡素化（`5edf2bc`）
- **Noun-Bigram 設定タブ** — content_bigram 管理 UI を削除（`5edf2bc`）
- **デバッグ `seed_noun_bigram` / `query_noun_bigram` / `set_last_noun`** — content_bigram 依存コマンドを削除（`5edf2bc`）

### 変更
- **デバッグ state** — `sessionTextBuffer` フィールドを追加（`b0b8f08`）
- **`docs/rejected.md`** — F-2 (content_bigram 廃止) を追記。F-1 の方針転換に「テーブルごと廃止した (F-2 参照)」を追記

---

## 2026-05-23〜24 — content_bigram・POS 分類・設定 UI

### 追加
- **content_bigram** — `noun_bigram` を `content_bigram` に置き換え、prev を名詞・固有名詞に加え動詞も対象に拡張。動詞 prev は LLM 品詞分類の `verb:confidence:lemma` で基本形に正規化し `history.lemma` にキャッシュ
- **POSCommitSequencer** — POS 分類（DB キャッシュ / LLM）と content_bigram 記録を分離し、確定順 FIFO で副作用を適用。連続確定時のサ変名詞誤分類を改善
- **LLM 品詞分類の拡張** — 固有名詞を `proper_noun` として名詞から分離。階層タグ（`product`/`work` 等）・自信度・再試行フラグを導入。文脈付き分類と `recentProperNouns` フィルタで精度を改善
- **Noun-Bigram 管理タブ** — 設定画面に content_bigram エントリの一覧・削除 UI を追加
- **変換履歴タブの拡充** — 「最終変換」列（`MM/dd HH:mm`）と品詞・回数・最終変換での昇順/降順ソートを追加

### 削除
- **変換履歴の AI スキャン** — Apple Intelligence 依存で実用性が低い `LLMCleanser` と「AI スキャン」シートを削除
- **Zenzai topic/style/preference** — 設定 UI 追加後 POC260524 で topic 自動推論を検証したが効果不足のためパラメータと UI を削除（`profile` のみ残存）

### 修正
- **連続確定時の content_bigram 記録** — `prevNoun` を POS 分類 completion 時点で読み取り、高速連続確定でもペアが記録されるよう修正
- **デバッグサンドボックス** — `useRealDB` を本番 DB 直結に変更し、reset 後の `posCommitSequencer` 再生成・POS/noun_bigram 記録経路を本番と一致させた

---

## 2026-05-23 — IME パイプライン簡素化・Successor 入力起動

### 追加
- **Successor の履歴前方一致** — noun-bigram が空でも `isNounLike` な prev 語から Successor を起動し、`fetchHistoryPrefix` の結果も候補にマージ（例: 「東京」確定後に `t` →「タワー」）
- **デバッグサンドボックス行ベース UI** — 左ペインを行単位ログに再構成。`get_log` の行単位返却・行コピー・`set_left_context` / `isZenzaiEnabled` フィールドを追加

### 変更
- **Successor を入力起動に統一** — 確定直後フラグ（`isSuccessorMode` / `suggestSuccessors`）を廃止。組成空の 1 打目 ASCII 入力で `leftSideContext` から prev を取り候補を試す設計に一本化
- **Successor を noun-bigram 予測に特化** — 格助詞 fallback リストを削除。noun-bigram → 履歴前方一致の 2 ソースに整理（後日 content_bigram に移行）
- **候補リスト組み立ての再構成** — `CandidateAssembler` を純粋関数化しセクション宣言的に再構成（PLAN260519）

### 削除
- **LLMSegmentConverter** — Zenzai ON 環境で効果がなく、セグメント LLM 全文一括変換を削除
- **LLMMisconversionChecker** — 確定後のオンデバイス LLM 誤変換スキャンを削除し LLM リソースを POS 分類に集中
- **`boundary_pref` テーブルと境界学習** — セグメント手動境界の永続化を廃止
- **確定時 shadow segmentize 学習** — Enter 確定後の非同期セグメント分割による `recordPrefixes` 登録を廃止
- **仮想文脈（virtualHistoryPrefix）** — IMK カーソル前文注入を試行したが Phase 2 で廃止

### 修正
- **Successor チェーン** — 格助詞確定後は連鎖を停止。Backspace 時に eligible 状態をクリア
- **`nn` + 母音** — `hiddenPendingN` を破棄し母音単体（`na` 等）に変換するよう修正
- **KanaKanjiConverter 並行アクセス** — `NSLock` で `converter.*` 呼び出しを直列化（`Task.detached` からのデータ競合防止）

---

## 2026-05-20〜22 — noun_bigram・候補品質・Zenzai プロモーション

### 追加
- **noun_bigram** — 名詞ペア共起学習を導入し Successor / 予測候補の prev 語予測に利用（後日 content_bigram に移行）
- **LLM 履歴名詞フィルタ** — 変換履歴候補を LLM 品詞分類で名詞系のみに絞り込み
- **Zenzai top-1 プロモーション強化** — 履歴なし autoShow 時に Zenzai 第 1 候補を先頭に昇格。続けて履歴あり時も初期表示されるよう修正
- **カタカナ候補を末尾に常時追加** — 候補リスト末尾にカタカナ変換を常設
- **Successor 長候補分割** — 助詞境界で長い表層候補を分割して表示

### 変更
- **履歴の `is_noun` を `pos` 列に拡張** — 品詞テキスト（`noun` / `proper_noun:person` / `verb` 等）を DB に保存し、LLM による履歴候補の名詞フィルタリングに利用
- **N-gram 学習の一本化** — ユーザー bi-gram / trigram / skip-bigram 学習を廃止。preset_bigram（固定ペア）+ noun_bigram（後に content_bigram）に移行
- **Successor を名詞末尾限定から拡張** — 当初は漢字・カタカナ末尾のみに制限したが、最終的には `isNounLike` 判定と入力起動モデルに統合（05-23）
- **autoShow 時のひらがな先頭固定** — 辞書のみ変換で候補が少ないときは全行表示し、読みのひらがなを row 0 に固定
- **セグメント学習** — `output == reading` のセグメント（未変換文節）は `recordPrefixes` をスキップ

### 修正
- **候補選択中の Space** — `isExplicitlySelected` 時に Space が再変換せず次候補へ移動するよう修正
- **変換履歴テーブル** — 「回数」列が隠れないよう列リサイズを修正
- **Zenzai 設定** — リセットバグの修正と保存フィードバックの追加

---

## 2026-05-17〜19 — hiraganaPreferred 一般化・候補順序・部分語学習

### 追加
- **ひらがな優先語彙の設定 UI** — `hiragana_preferred` テーブルを DB に追加し初回起動時にデフォルト 30 語をシード。設定画面に「ひらがな優先」タブを追加（語の追加・削除が可能）。変更時は `NotificationCenter` で `InputController` へ通知し Set を再読み込み
- **確定語のセグメント分割学習** — `doConfirmSelection`（autoShow 候補 → Enter 確定）で確定した語を AzooKey の `segmentize` で非同期分割し、2 文節以上に分かれた場合は各セグメントを `recordPrefixes` でも登録。「プロジェクトマネージャー」確定後に「ぷろじぇくと」→「プロジェクト」が履歴候補として出るようになる

### 変更
- **hiraganaPreferred を一般化** — 格助詞に限定していた `initialRow=0` ロジックを `hiraganaPreferred`（接続詞・口語表現等を含む上位集合）に拡張。「とか」「では」「これ」等でもひらがな固定候補を初期選択にする
- **ひらがな・カタカナ固定先頭挿入を廃止** — デフォルトでひらがな・カタカナを候補先頭 2 枠に挿入するロジックを廃止し `hiraganaPreferred` に一元化。これにより「いっきに」→「一気に」が先頭候補になるなど変換候補が自然な順序で表示される
- **外来語マーカーの拡充** — 長音符「ー」に加え小母音「ぁぃぅぇぉ」も外来語マーカーとして扱い、カタカナを初期選択にする（「ねいてぃぶ」→「ネイティブ」等）
- **前方一致履歴を辞書候補より前に表示** — `highHistory` 昇格条件から完全一致チェックを外しスコア閾値のみで判定するよう変更。「じょう」入力時に「情報共有」が履歴セクションに表示される
- **前方一致履歴を最大 3 件に制限** — 前方一致履歴の表示件数に上限を設け候補過多を抑制
- **isMixedKanaVariant・isSpuriousCompound フィルタを削除** — AzooKey の候補をフィルタリングすることで自然な混在表記（「ヒントだよ」等）が除外されていたため独自フィルタを撤廃し AzooKey の変換品質に委ねる

### 修正
- **格助詞入力時の初期選択ずれ** — 「の」「に」等の particles 入力時に履歴候補（「ノックアウト」等）が初期選択されていた問題を修正
- **ひらがな/カタカナ固定候補がある場合は辞書先頭昇格を抑制** — `shouldPromoteFirstDict` に `fixedCount == 0` 条件を追加し、純ひらがなが自然な読みではひらがな固定候補が辞書候補より優先されるよう修正

---

## 2026-05-16 — 候補先頭・初期選択・学習フィルタ最終調整

### 追加・変更
- **辞書先頭候補を row 0 に昇格** — ひらがな/カタカナ固定候補より前に辞書の最有力候補を置き、Space 連打なしで漢字が選べるようにした
- **初期選択フォールバック** — 履歴・予測候補がない場合はひらがな固定候補（row 1）を初期選択にする（`initialRow` ロジック修正）
- **擬似複合語フィルタ追加** — 混じりカナ語頭＋漢字末尾（カタカナ + kanji）の擬似複合語候補を除外
- **句読点を N-gram・履歴から除外** — 句読点確定を bi-gram / trigram / history に記録しないようにし、句読点が next-word 予測を汚す問題を修正

---

## 2026-05-15 — Bracket モード全記号対応・Successor 遅延起動

### 追加
- **Bracket モード拡充** — `/`・`.`・`,`・`!`・`?` および記号キー全般を `bracketOptions` に移行し、AzooKey 辞書と統一した全角/半角候補リストを候補ウィンドウで選択できるようにした
  - `!` は `Shift+1` 起源でも bracketOptions を発動
  - US キーボードの `Shift+/`（`?`）で「？」が開かなかった問題を修正済み（05-12）

### 変更
- **Successor 遅延起動** — 確定直後の即時候補表示を廃止し、1打目入力まで遅延。誤トリガーと画面チラつきを抑制

---

## 2026-05-13〜14 — 候補品質向上・変換精度・セグメント LLM プリフェッチ

### 追加
- **セグメント LLM プリフェッチ** — `taskGeneration` と prefix-aware restarts で LLM 変換候補を非同期先読みし、セグメントモードのレイテンシを削減
- **プリセット Bi-gram 拡充** — `preset_bigram.csv` を 305 件 → 1086 件に増強、シードキーを v2 にバンプ

### 変更
- **highHistory 昇格条件を厳格化** — 完全一致読みの履歴のみを先頭グループに昇格し、複合語を末尾に移動することで候補ヘッドの精度を向上
- **Successor モードを抑制（文中挿入時）** — カーソルが文末でない状態での Successor モード起動を禁止
- **ひらがなパススルー確定を history から除外** — スペースなし確定（ひらがなそのまま）を学習しない

### 修正
- **擬似複合語フィルタ** — ひらがな先頭・漢字末尾・同文字数の候補（「こうした居」等）を除外
- **促音誤分割** — 促音終わりのセグメント（「せっ」+「ていがめんの」→「せってい」+「がめんの」）を正しく分割
- **複合変換候補の欠落** — 活用語＋助動詞の複合候補（「頼みたい」等）が消える問題を修正
- **複合変換候補に残余ひらがな混入** — AzooKey の複合変換候補に余分なひらがなが混入する問題を修正
- **未知語でスペース無反応** — 辞書候補なし（未知語）の状態でスペースが何も起きない問題を修正
- **1文字助詞の初期選択ずれ** — `の/は/が/を` 等のデフォルト選択が履歴候補にずれる問題を修正
- **音便形変換** — `lcid` 品詞判定で助詞・助動詞末尾の音便形変換を正しく通すよう修正

---

## 2026-05-12 — 設定 UI 刷新・Zenzai ラベル・学習ロジック改善

### 追加
- **Tri-gram タブ** — 設定画面に Tri-gram 一覧・削除 UI を追加
- **LLM クレンジングタブ** — 誤確定候補を LLM でクレンジングするタブを追加（Apple Intelligence 未有効時はリンクを表示）
- **Zenzai 候補ラベル** — Zenzai がプロモートした候補に「Zenzai」ラベルを紫色で表示
- **Successor 候補数上限** — Successor モードの候補数を最大 5 件に制限

### 変更
- **格助詞 prev を bigram から除外** — 格助詞を `prev` とする bigram 記録をスキップし trigram に集約（`の/に/を` 等の汎用ペアによるノイズを削減）
- **プレフィックス記録廃止** — 読みのプレフィックスを個別記録せずフル読みのみ保存するよう統一（DB 肥大化対策）
- **設定画面再編** — クレンジングタブを廃止し Bi-gram / 変換履歴タブ内シートに統合

### 修正
- **ユーザー辞書消失** — deploy 後にユーザー辞書テーブルが空になる問題を修正（DB パス解決バグ）
- **部分読み確定の集計** — `fetchHistoryScoredMerged` を `LIKE + SUM` に統合し、部分読み確定の回数を正しく集計

---

## 2026-05-10 — 入力エッジケース修正

### 修正
- **`nn` + 句読点/F6 の pending n 整合** — `nn` 直後のスペース・句読点・F6 で `hiddenPendingN` が `finalizedText` と不整合になる問題を修正
- **pending-only ローマ字でスペースを消費** — 組成文字が pending ローマ字のみの場合でもスペースを消費し、候補ウィンドウを開くように修正
- **セグメント右矢印で selectedText を保持** — 右矢印でセグメントを再構築する際に選択テキストが失われる問題を修正

---

## 2026-05-06 — Zenzai 統合強化・デバッグサンドボックス拡充

### 追加
- **Zenzai top-1 プロモート** — Zenzai の第 1 候補をユーザー辞書直後（AzooKey 辞書候補より前）に表示（PLAN260506）
- **Zenzai 左文脈補完** — `committedHistory` を Zenzai の左文脈として渡し、前後文脈を考慮した変換精度を向上
- **Zenzai 優先セグメント** — セグメントモードで Zenzai 候補を先頭に並べ、`historyEnd` を正しく設定
- **デバッグサンドボックス大幅拡充** — `DebugSocketServer` に AI 向け高レベルコマンド・suite runner・`assert_eventually`・`wait_until`・スキーマアサーション・キャプチャ変数・テンプレート再利用・fail-fast モードなど多数のコマンドを追加（`keynaco-ime-sandbox` スキル対応）

### 変更
- **`DatabaseManager` 分割・`InputHandler` モジュール化** — `KeynacoCore` 内部を責務ごとに分割し、LLM 配線を再整理（PLAN260506c）

### 修正
- **子音直前の `nn` 重複耐性** — `nn` の後に子音が続く場合の重複入力を許容するよう修正

---

## 2026-05-05 — Zenzai 有効化・KeynacoCore パッケージ分割

### 追加
- **Zenzai 有効化** — AzooKey の Zenzai モデル（`zenz-v3.1-small-gguf`）を Package trait で有効化。設定 UI に Zenzai タブを追加。Space 変換時に `requestRichCandidates` を有効化
- **`zenz-v3.1-small-gguf` submodule** — Zenzai モデルを git submodule（LFS 管理）として追加

### 変更
- **`KeynacoCore` パッケージ分割** — 入力ロジック・DB・LLM 補助を `Core/` 配下の Swift Package として分離し、アプリターゲットからローカル SPM 参照する構成に移行（PLAN260505）
- **`LLMCandidateScorer` 廃止** — 後処理による候補並べ替えを削除し、Zenzai によるオンデバイス rerank に一本化

### 修正
- **`FoundationModels` クラッシュ** — `CandidateWindow` の配列アクセス違反と FoundationModels 初期化クラッシュを修正
- **「でも」部分変換と Enter 誤確定** — 部分変換候補が表示されたまま Enter を押すと誤確定する問題を修正

---

## 2026-05-04 — F1 同音異義語自動選択の精度向上

### 変更
- **F1 文脈窓拡大** — `surroundingText` の取得・切り詰め上限を 100 → 300 文字に拡大し、段落レベルの話題を LLM に渡せるようにした
- **F1 文脈補強** — `committedHistory.suffix(5)` を文脈の先頭に付加。`surroundingText` が空になる Electron 系アプリでもフォールバックとして機能する
- **F1 確信度フラグ** — `LLMCandidateScorer` の返答フォーマットを `番号:high/mid/low` に変更し `ScorerResult(index:confidence:)` を返すよう拡張。`low` はコールバック非呼び出し、`mid` は非 autoShow 時のみ候補を移動する
- **F1 autoShow 対応** — `lastF1Eligible` から `!autoShow` 条件を撤廃し、文字入力中（autoShow）でも F1 が起動するように。`high` 確信度の場合のみ autoShow 中に `moveRow` を実行する
- **テスト** — `parseChosenIndexWithConfidence` の境界例（スペース入り・大文字混在・`2:unknown`・コロンなし・範囲外）を追加

> 関連: [PLAN260504a](plans/PLAN260504a-homophone-auto-select.md)

---

## 2026-05-04 — IMKTextInput 経由の文書文脈取得

### 追加
- **`SurroundingIMKContext`** — `IMKTextInput.attributedSubstring(from:)` / `length()` を使い、カーソル前後のテキストを安全に取得するユーティリティを新設。`NSNotFound` ガード・`beforeLength` 実長計算・`totalLength` クランプの3点を徹底し、クライアントアプリのクラッシュを防ぐ
- **文書文脈キャッシュ** — `InputController` に `cachedSurroundingContext(location:text:)` を追加。`composedHiragana` が空→非空になったタイミングで1回だけ取得し、`selectedRange().location` 変化時に自動無効化（カーソル移動対策）
- **`resolvedLLMDocumentContextPrefix`** — `LLMCandidateScorer` / `LLMSuccessorFetcher` に渡す文脈を「`before` 非空 → 末尾300字」「`before` 空 or `nil` → `committedHistory.suffix(5)`」の優先順で解決するヘルパーを追加
- **テスト** — `MockIMKTextInputForSurrounding`（テストダブル）を使った境界テスト6件（`NSNotFound`・文頭・文頭付近・`totalLength == NSNotFound`・文末・通常ケース）を追加

> 関連: [PLAN260504b](plans/PLAN260504b-imk-surrounding-context.md)

---

## 2026-05-03 — オンデバイス LLM（候補・後続語・セグメント・誤変換）・プリセット Bi-gram・学習ペナルティ

### 追加
- **F1 文脈スコアリング** — `LLMCandidateScorer` で変換候補を文脈に応じて並べ替え（`moveRow` 連携）
- **F3 後続語オンデバイス補完** — `LLMSuccessorFetcher` で Successor 候補列の末尾を補強（冷スタート時など）
- **F2 セグメント全文一括変換** — `LLMSegmentConverter` でセグメントモードに LLM による全文一括変換候補を追加。`inferSegmentBoundaries` で多文節の境界を推定できた場合は境界ごとに再構成し、失敗時は先頭文節の先頭候補へ全文を入れる従来フォールバック
- **多文節境界の永続化** — LLM で推定した境界を確定時に `boundary_pref` へ保存
- **F4 誤変換検出** — `LLMMisconversionChecker` とメニュー連携で確定後の誤変換を検知
- **確定直後 Backspace** — 直前に確定した変換に対し、履歴・N-gram・境界学習へ一括でペナルティ（ネガティブフィードバック相当）
- **プリセット Bi-gram バンドル** — `preset_bigram.csv` の初回シード、`bigram.is_preset`、閾値集計・GC・インポート時のプリセット行保護
- **`boundary_pref` 強化** — 読みの前方一致取得と、短すぎる読みでの保存ガード
- **セグメント候補と履歴** — プレフィックス履歴をセグメント候補にマージ
- **低スコア履歴の位置** — `fetchHistoryScoredMerged` で閾値未満の履歴を AzooKey 辞書候補の後ろに回し、ヘッドの候補品質を優先
- **保留中 Successor の通知** — メニューバーアイコンで、閾値待ちの後続語候補があることを表示（P5）

### 変更
- **テスト** — LLM フォールバック用の AzooKey スタブを共通化

### 削除
- **ゴーストテキスト（FoundationModels オーバーレイ）** — 2026-05-02 に試験導入したが P0 で削除（Apple Intelligence 後続予測のオーバーレイ表示・Tab 確定連携など）

---

## 2026-05-02 — 学習 DB のクラッシュ回復・メニューバーアイコン表示

### 追加（試験・後に削除）
- **ゴーストテキスト** — 変換確定後に後続をオーバーレイ表示し Tab で確定する試験実装（翌日削除。履歴は上記 2026-05-03）

### 修正
- **学習データ整合性** — クラッシュ後の不整合を `commit_lock` で検出し自動回復（`AzooKeyConverter` 周り）
- **入力ソースアイコン** — `TISIconIsTemplate` をやめ、メニューバーでフルカラーの角丸ボックス表示に統一

---

## 2026-05-01 — 数字候補・パフォーマンス・セグメントガード・デプロイ

### 追加
- **数字候補** — 数字のみ入力時に全角数字・桁区切りなどの候補を自動生成（履歴には記録しない）

### 変更
- **パフォーマンス** — DB 書き込みのバックグラウンド化、AzooKey 学習の非同期化、SQLite プリペアドステートメントキャッシュ、履歴／ユーザー辞書の exact+prefix を UNION ALL で統合、`mostRecentContentWord` のループ外寄せ、`removeAll` の走査削減など（TDD 計画に沿った節約）
- **デプロイ** — Apple Development 証明書がない環境ではアドホック署名にフォールバック

### 修正
- **セグメント変換** — ASCII 読みをセグメント変換の対象にしないガード

---

## 2026-04-30 — z シーケンス特殊文字

### 追加
- **`z` + 記号・矢印** — 組成中・組成前どちらでも `z-` → `〜`、`z/` → `・` など特殊文字を即時挿入（`zCharMap` / `zArrowMap`）

---

## 2026-04-29 — 日時候補の動的追加

### 追加
- **日時候補** — 読みが `きょう` / `きのう` / `あした` / `あす` / `いま` / `ことし` / `きょねん` / `らいねん` / `こんげつ` / `せんげつ` / `らいげつ` のとき、変換候補の末尾（履歴の後・AzooKey 辞書候補の前）に日付・時刻・年の文字列を動的に追加。例: `きょう` → `2026年4月29日` / `4月29日` / `2026-04-29` / `2026/04/29`
- 日時候補を確定しても history / bigram / trigram に記録しない（`commitText(skipHistory:)` 引数で制御）

---

## 2026-04-29 — セグメント境界の学習

### 追加
- **セグメント境界学習（B-1）** — セグメントモードで Shift+矢印による手動境界調整を確定すると、その境界を `boundary_pref` テーブルに保存。次回同じ読みで Space を押すと AzooKey の初期分割ではなく保存済み境界で再現する。上書きポリシーは最後に確定した境界を優先（`ON CONFLICT DO UPDATE`）
- `DatabaseManager` に `saveBoundaryPref` / `fetchBoundaryPref` を追加
- `performGCIfNeeded()` の対象に `boundary_pref` を追加（180日未使用で削除）

> 関連: [PLAN260429e](plans/PLAN260429e-segment-boundary-learning.md)

---

## 2026-04-29 — ユーザー辞書・外来音ローマ字拡充・候補品質改善・DB 自動 GC

### 追加
- **ユーザー辞書（F-1）** — 固有名詞を読み（ひらがな）→登録テキストとして永続登録できる `user_dict` テーブルを追加。登録エントリは変換候補の先頭（カナ固定直後・予測より前）に表示。time-decay なし
- 設定画面に「ユーザー辞書」タブを追加（読み+登録テキストの入力フォーム・削除。ひらがなバリデーション付き）
- ステータスバーメニューに「ユーザー辞書...」項目を追加（クリックで直接タブを開く）
- `CandidateAction.show` / `CandidateContext` に `fixedEnd` を追加し、ユーザー辞書行の Shift+Delete 誤削除を防止

---

## 2026-04-29 — 外来音ローマ字拡充・候補品質改善・DB 自動 GC

### 追加
- ゔ行・ウ行拡張（`wu` → `う` 等）・`di` → `でぃ` などの外来音ローマ字テーブルを拡充
- 候補ウィンドウにセクションラベルを表示（固定・履歴・辞書の区別を明示）
- ネガティブフィードバック機能（確定しなかった候補を学習スコアから減衰させる）
- セグメント確定時に bi-gram を記録する仕組み（文節変換の学習品質向上）
- **DB 自動 GC** — `count=1` かつ 180日以上未使用のエントリを全 4 テーブルから削除し `VACUUM` を実行（7日に1回、起動時バックグラウンドで実行）
- **セグメント候補への bi-gram 活用** — `buildSegmentCandidates` が前語コンテキスト（`prev`）を受け取り、`fetchBigram` の結果を固定候補の直後・履歴の前に挿入。セグメント進入時は `lastCommittedOutput` を起点にカスケードで引き継ぎ、右矢印移動時は移動元の選択テキストを prev として次セグメントをリビルド

### 修正
- `fetchHistoryPrefix` で同一出力が複数行返る重複候補を `GROUP BY output` で排除

> 関連: [PLAN260429](plans/PLAN260429-ime-quality-trio.md) · [PLAN260429b](plans/PLAN260429b-section-gc.md) · [PLAN260429c](plans/PLAN260429c-backspace-reconvert.md) · [IDEA260429](ideas/IDEA260429.md)

---

## 2026-04-28 — 括弧モード・N-gram フィルタ・pendingRomaji 先読み

### 追加
- **括弧モード** — `[` / `(` / `{` 等の括弧キー入力時に全角括弧の候補ウィンドウを表示して選択できる
- **N-gram フィルタ** — Successor 候補を1打目の読み前方一致でフィルタリング（低信頼ペアの誤表示を抑制）
- **高信頼 bi-gram 即時表示** — 閾値（`successorImmediateThreshold` = 5回以上）を超えたペアを確定直後に即時表示
- **pendingRomaji 先読み予測** — 組成前の1文字入力時に bi-gram/trigram/skip-bigram を先読みし、候補があれば Successor モードへ移行

> 関連: [PLAN260428](plans/PLAN260428-successor-pending-romaji.md)

---

## 2026-04-27 — 学習強化・Successor チェーン・イベントビューアー

### 追加
- **trigram** — 2語前コンテキストを使った予測で変換精度を向上
- **英字単語モード** — 日本語モードのまま `GitHub` 等の混在ケース英語を入力可能
- **ASCII 英字学習** — 英字入力を変換履歴として記録し候補表示に反映
- **`recordPrefixes`** — 読み省略パターン（`東京` → `とう` / `とうきょ` 等）を自動学習
- **文節 Space 確定学習** — セグメントモードで Space 確定したフレーズ全体を bi-gram/trigram として記録
- **skip-bigram** — 助詞をまたいだ語間（`東京` → `行く` 等）を学習
- **時間減衰スコアリング** — `count / (1 + age_days / 30)` を全 fetch SQL に適用し古い履歴を自然に降格
- **Successor チェーン** — 候補確定後に次の bi-gram 候補があれば連続して候補を表示
- **文末リセット** — 句点・感嘆符・疑問符・改行確定時に `committedHistory` をクリアし文をまたぐ n-gram 学習を防止
- **イベントビューアー** — メニューバー常駐ウィンドウ（⌨アイコン）でキーコード・確定テキスト・候補をリアルタイム表示。JSONL エクスポート対応

### 修正
- `nn` → `ん` 後の pending `n` を不可視化する標準 IME 準拠挙動（`hiddenPendingN`）
- 入力ソースアイコンのキー名・フォーマット（TIFF）と、キーボード設定での表示名を修正

> 関連: [PLAN260427](plans/PLAN260427-trigram-extension.md) · [PLAN260427b](plans/PLAN260427b-codebase-refactor.md) · [PLAN260427c](plans/PLAN260427c-domain-docs-sync.md) · [PLAN260427d](plans/PLAN260427d-learning-keystroke-reduction.md) · [PLAN260427e](plans/PLAN260427e-phrase-learning-decay.md)

---

## 2026-04-20 — Successor モード一般化

### 変更
- 格助詞モード（`isParticleMode`）を **`isSuccessorMode`** にリネームし、格助詞に限らず全確定語の直後に bi-gram 予測を表示するよう拡張
- 格助詞リストのフォールバック表示は名詞（漢字・カタカナ末尾）直後のみに制限

> 関連: [PLAN260420](plans/PLAN260420-prediction-type-reduction.md)

---

## 2026-04-18〜19 — keynaco リネーム・設定 UI・格助詞予測

### 追加
- プロダクト名を **ykey → keynaco** にリネーム
- アプリアイコンと `make_icons.swift` による自動生成スクリプト
- `git tag` からバージョン番号を `CFBundleShortVersionString` / `CFBundleVersion` に自動注入（post-action）
- AzooKeyKanaKanjiConverter をリモート SPM 依存に切り替え（v0.11.2）
- **格助詞クイック選択** — 確定直後に格助詞リスト（を・に・で・へ・と…）を自動表示し、頭文字1打で即確定
- **設定画面** — bi-gram エクスポート/インポート・変換履歴一覧・bi-gram 一覧・削除 UI（`NSTabViewController`）
- `TISRegisterInputSource` による起動時の自動登録
- 候補選択中の右矢印でひらがな組成に戻す（Electron 系アプリでの Enter 問題を回避）

> 関連: [PLAN260418](plans/PLAN260418-azookey-engine-migration.md)

---

## 2026-04-17 — AzooKey 変換エンジン移行

### 追加
- 履歴の前方一致補完（入力中に補完候補をリアルタイム表示）
- 辞書候補の自動表示（2文字以上のひらがな入力で発動）
- Shift+Delete で選択中の履歴候補を変換履歴 DB から削除
- 候補ウィンドウに履歴/辞書の区別を視覚表示（セパレーター行）

### 変更
- 変換エンジンを SKK-JISYO-L / mozc システム辞書から **AzooKeyKanaKanjiConverter** に移行（組み込み辞書使用）

### 削除
- mozc システム辞書・ビルドスクリプト・okuri-ari 展開スクリプト
- SKK-JISYO-L 関連ファイル

> 関連: [PLAN260417](plans/PLAN260417-mozc-dictionary.md)

---

## 2026-04-12 — 文節変換・カタカナ候補・句読点変換

### 追加
- **文節（ぶんせつ）変換モード** — Space で AzooKey 変換を起動し、Shift+矢印でセグメント境界を1文字単位で調整
- **カタカナ固定候補** — 候補リスト先頭にカタカナ変換を挿入（F7 と同等の候補をワンクリックで選択可）
- 句読点変換 — `,` → `、` / `.` → `。`（かなモード中のみ）
- 組成中に句読点を入力したとき候補ウィンドウを開く
- `InputHandler` を `InputController` から分離し XCTest によるユニットテストを可能にした

> 関連: [PLAN260412](plans/PLAN260412-segment-split-conversion.md) · [PLAN260412b](plans/PLAN260412b-segment-dp-history-scoring.md)

---

## 2026-04-11 — ビルド自動化・テスト基盤

### 追加
- Xcode scheme post-action によるビルド→`/Library/Input Methods/` への自動コピーとプロセス再起動
- `CompositionState`（未確定文字列の状態）を `InputController` から分離しテスト可能に

> 関連: [PLAN260411](plans/PLAN260411-local-dev-improvements.md)

---

## 2026-03-14 — 初期実装

### 追加
- macOS 向け IME の初期実装（InputMethodKit + SQLite、Swift 6 strict concurrency）
- ローマ字→ひらがな変換（`RomajiConverter`）
- SKK 辞書による漢字変換（後の 2026-04-17 で AzooKey に移行）
- カスタム候補ウィンドウ（`NSWindow(.borderless)` + `NSTableView`、`IMKCandidates` は非採用）
- 矢印キー・Shift+Tab による候補ナビゲーション
- 英数/かなキーによる ASCII モード切り替え（`isAsciiMode` はアプリをまたいでグローバルに保持）

> 関連: [IDEA260327](ideas/IDEA260327.md)
