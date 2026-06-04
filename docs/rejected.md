# 不採用機能

試作・検討したが採用しなかった機能の記録。同じアイデアを再検討する際の参考にする。

---

## S-1 NAS DB 同期（Settings タブ）（2026-06-05 削除）

**概要**: Settings の「同期」タブで NAS 上の `history.db` パスを指定し、rsync でローカル DB と手動／終了時自動で同期する機能。`SyncSettings` + `SyncViewController` + `AppDelegate.applicationWillTerminate` の書き出し。

**試みたこと**: SMB マウント先への rsync（`-av --checksum`）。インポート前に WAL チェックポイント・接続クローズ（`closeForImport`）して WAL/SHM 破損を防ぐ。終了時自動書き出しオプション。

**削除の理由**:

- **利用場面がない**: 単一マシン運用で NAS 同期を使う機会がなく、Settings タブが dead code になっていた
- **rsync 依存の運用コスト**: パス設定・マウント状態・競合解決はユーザーが手動で面倒を見る必要があり、IME 本体に UI を持つ ROI が低い
- **代替は十分**: マシン間共有が必要になった場合は `~/Library/Application Support/keynaco/history.db` を iCloud / 手動 rsync / バックアップツールで扱えばよく、専用タブは不要

**削除した周辺**: `SyncSettings.swift` / `SyncViewController.swift`、`DatabaseManager.checkpoint` / `closeForImport` / `reopen`。

**再検討するなら**: 複数 Mac で履歴・ユーザー辞書を常時同期する需要が実際に出てから。自動マージ（Last-Write-Wins ではなくフィールド単位）が必要なら POC から。

> 関連: [concept.md](./concept.md)（NAS 同期の言及 — UI 実装は本エントリで不採用）

---

## J-1 日記自動生成（Settings タブ）（2026-06-05 削除）

**概要**: `daily_log`（確定テキスト＋app_bundle_id）を素材に、Apple Intelligence（Foundation Models）で 1 日分の日記・日報を生成する Settings「日記」タブ。`DiaryViewController` + `DiaryGenerator` + `diary` テーブルへの保存。

**試みたこと**: 日付選択 → 当日の `daily_log` 一覧表示 →「日記を生成」→ 生成結果の編集・保存・コピー。Guided Generation の動作確認は [PLAN260527](../plans/PLAN260527.md) で完了済み。

**削除の理由**:

- **利用場面がない**: 日報・振り返りを Settings から生成するワークフローを日常的に使わず、タブが dead code になっていた
- **IME のコア価値とずれる**: 入力支援（履歴・Zenzai・候補）が主役であり、生成物の閲覧・編集 UI を IME 設定に持つ必然性が薄い
- **データ基盤は別途保持**: `daily_log` への記録（`InputHandler.diaryBuffer` → `recordDailyLog`）は personalization 用コーパスとして継続。削除したのは生成 UI と `DiaryGenerator` のみ

**削除した周辺**: `DiaryViewController.swift` / `DiaryGenerator.swift`、`DatabaseManager.saveDiary` / `fetchDiary` / `fetchDiaryDates`。既存 DB の `diary` テーブルはスキーマ上残るが未使用。

**再検討するなら**: `daily_log` が数万字規模に育った後、日記生成ではなく personalization（[G-2](#g-2-tunerax-スクレイピング型-personalization-基盤の追加2026-05-29) 参照）の方が優先。日記 UI を復活させるなら独立アプリ or ショートカット連携の方が適切。

> 関連: [PLAN260527](../plans/PLAN260527.md)、[apple-intelligence.md](./apple-intelligence.md)

---

## I-1 セグメントモード（文節選択 / AzooKey Desktop `.selecting` 相当）（2026-06-04 削除）

**概要**: Space で長文読みを文節単位に部分確定するモード。`SegmentState` + `AzooKeyCandidateMerge` + `firstClauseResults` マージ + Shift+←/→ 境界調整 + marked text 二重下線。azooKey-Desktop の `.selecting` を keynaco 向けに再実装したもの。

**削除の理由**:

- 境界ヒューリスティック（助詞リスト・「は」直前・です/ます剥がし等）の保守コストに対して体感がイマイチ。POC260603 で段階改善したが、エンジン部分候補 + keynaco 固有ルールの二重構造が残り続けた
- 多くの入力（2 文字以下・ひらがな優先・日時/ユーザー辞書）は既に通常候補窓へフォールバックしており、Space の主役が中途半端
- セグメント間 bigram 学習・LLMSegmentConverter・読み修正（C-1）は既に不採用/削除済みで、モード単体の価値が薄い
- `concept.md` の打鍵最小化は履歴・Zenzai 文脈・予測変換で取りに行く方針。文節モードは差別化の核にならなかった

**削除後の Space**: 組成中 Space → `buildCandidateList(autoShow: false)`（候補窓表示）。候補表示中 Space → 次候補（従来の ↑↓ 明示選択フローは維持）。

**同時に廃止した周辺**: セグメント確定時の結合フレーズ `recordPrefixes`（`observation.md` 経過観察からも削除）、`scripts/check_segment_history_boundary.py` / `segment_boundary_compare.py`、デバッグ JSON の `isSegmentMode` / `segmentTexts` フィールド。

**再検討するなら**: 使い込みで「長文を一気に打って Space 1 回で部分確定」が本当に必要か POC から。AzooKey Desktop 追従そのものを目的にしない。

> 関連: [POC260603](../plans/POC260603.md)、[PLAN260603](../plans/PLAN260603.md)、[C-1 セグメントモード内の読み修正](#c-1-セグメントモード内の読み修正2026-04-30)

---

## G-2 Tuner（AX スクレイピング型 personalization 基盤）の追加（2026-05-29）

**概要**: Zenzai の `personalizationMode`（base/personal n-gram LM の補間）に渡す personal モデルを
生成・データ蓄積する手段として、azooKey の **Tuner**（github.com/azooKey/Tuner, MIT）を keynaco に
足すか検討した。Zenzai personalization 自体の効果検証は [POC260529](../plans/POC260529.md) で実施。

**調査した内容**: Tuner は SwiftPM ライブラリではなく**独立した macOS メニューバーアプリ**（`.xcodeproj`）。
2層に分かれる:
- **取得層**: アクセシビリティ API で**全アプリの画面テキストを常時スクレイピング**。`app-sandbox: false`、`NSAccessibilityUsageDescription` 必須。
- **学習パイプライン層**: MinHash＋前方一致で重複除去（`MinHashUtils` / `TextModel+Purification`）→ EfficientNGram で n-gram 逐次学習（`TextModel+NGram`）。App Group 経由で IME にモデルを渡す。

**不採用の理由**:

- **取得層がポジショニングと衝突**: keynaco は `app-sandbox: true`／concept.md「ローカル完結」「学習データはローカル SQLite に閉じる」。Tuner の取得層はサンドボックス解除＋Accessibility 権限＋閲覧内容の全収集を要求し、「入力を学習」から「画面で見た全テキストを収集」へ信頼契約が質的に変わる
- **取得層がそもそも不要**: keynaco は IME なので `daily_log`（打鍵＋app_bundle_id）が privacy を守ったまま育つドメインコーパスになる。azooKey が AX スクレイピングをする理由（入力だけだとデータが貯まるのが遅い）は本 POC のデータ量律速の解決策だが、keynaco にとっては最も避けるべき取り方
- **時期尚早**: personalization 自体が [POC260529](../plans/POC260529.md) でデータ量律速（2日で2470字）と判明し status=tested で保持中。Tuner を今組んでもデータが貯まるのを待つだけ

**判断**: Tuner アプリの追加（特に取得層）は不採用。**ただし personalization 機構そのものは棄却ではない**
（POC260529 で「データ待ちで保持」）。将来 personalization を本採用するなら、Tuner 一式ではなく
**dedup ロジックだけ MIT 流用**（MinHash／前方一致は実装の質が高い）し、`daily_log` からの増分学習に
組み込む。取得層は捨てる。

> 関連: [POC260529](../plans/POC260529.md)、[G-1 Zenzai 制御パラメーター](#g-1-zenzai-制御パラメーターtopic--style--preference-の-ui-公開2026-05-24)

---

## H-1 FoundationModels @Generable 構造化出力による品詞分類（2026-05-25）

**概要**: `LLMPOSClassifier` のプレーンテキストパース方式を廃止し、`@Generable` + Guided Generation（`respond(generating:)`）で品詞ラベルを構造化出力させる。スキーマ違反トークンを生成できなくなるためガベージ出力問題を根本解決できると想定した。Tool Calling（`struct POSTagTool: Tool`）も代替アプローチとして検証した。

**試みたこと**:

- `@Generable struct POSResultV2`（`pos: String` + `.anyOf(...)` 制約）で `respond(generating:)` を呼ぶ
- フィールド1つのみの最小 `@Generable struct SmokeTestResult` で smoke test
- `struct POSTagTool: Tool`（`Arguments = POSToolParameters`、返り値 `String`）+ `respond(to:)` の Tool Calling アプローチ

**結果**: 3アプローチすべてで `respond` が返らない永続的ハング（45秒タイムアウト確認）。エラーも例外も投げない。

**不採用の理由（根本原因）**:

- IME Extension（Input Method Extension）には通常アプリより厳しいサンドボックスプロファイルが適用される
- Guided Generation のスキーマ検証・Tool 呼び出しは `generatived` / `com.apple.modelcatalog.catalog` への XPC 通信を経由する
- IME サンドボックスが XPC 通信を拒否（Error 159: Sandbox restriction）
- クライアントプロセスに完了シグナルも例外も届かないままデッドロック
- コードの問題ではなく **macOS 26 Beta のシステムバグ**。workaround なし

**判断**: OS アップデートで修正されるまで利用不可。`respond(to:)` プレーンテキスト方式（現行 `LLMPOSClassifier`）は動作するため、プロンプト改善で精度向上を図る方針に切り替え（→ [PLAN260525b](../plans/PLAN260525b.md)）。将来 Apple が IME Extension のサンドボックスポリシーを緩和した場合に再評価する。

> 関連: [POC260525b](../plans/POC260525b.md)

---

## G-1 Zenzai 制御パラメーター（topic / style / preference）の UI 公開（2026-05-24）

**概要**: zenz-v3 の制御トークン `topic`・`style`・`preference` を設定 UI に追加し、ユーザーが文書の話題・文体・好みを手動設定できるようにした。また `DatabaseManager.recentProperNouns(limit:)` で history.db の固有名詞を自動推論して `topic` に補完する PoC も実施した。

**試みたこと**: `ZenzaiViewController` に topic/style/preference の入力フィールドを追加。`ZenzaiSettings.makeConverter()` でこれらを制御トークンとして AzooKey API に渡す実装。topic 自動推論は `pos IN ('proper_noun/place', 'proper_noun/person', 'proper_noun/org')` かつ `pos_retry=0` のエントリを上位 5 件取得してカンマ区切りで渡す方式（詳細は `plans/POC260524.md`）。

**不採用の理由**:

- **leftSideContext が支配的**: 同音異義語の disambiguation は `leftSideContext` だけで十分に機能する（`すいふと` + 技術文脈 → SWIFT プロモート、`じゃば` + 蛇文脈 → 蛇場/蛇ば など）。topic の追加効果を単独で確認できなかった
- **zenz-v3.1-small では topic が無効**: `topic="Swift,GitHub,Xcode,Apple"` および `topic="IT,プログラミング,技術"` を設定しても、全テストケースで topic 空と差異なし。fixedEnd も変化しなかった（POC260524.md シミュレーション実測）
- **topic 自動推論はノイズが多い**: `LLMPOSClassifier` の誤分類率が高く、直近固有名詞の上位が common noun（`入力`・`固有名詞`）や助詞付き語彙（`情報が`）で占められる。有害なバイアスになる可能性がある

**判断**: UI から topic/style/preference を削除し `profile` のみ残す。自動推論コード（`recentProperNouns`）は現状維持するが ROI を投じない。将来の zenz-v3 上位モデルで再評価する。

> 関連: [POC260524](../plans/POC260524.md)

---

## F-1 Successor モード（後続語サジェスト）（2026-05-25）

**概要**: 組成なし・ASCII モードでない状態で ASCII 英字 1 文字を入力した瞬間、直前確定語（または `leftSideContext` 末尾の名詞）を prev として content-bigram + 変換履歴を照会し、後続語候補を表示するモード。確定後さらにローマ字を打つことで仮名プレフィックスで候補を絞り込む。

**試みたこと**: `InputHandler+SuccessorMode.swift`（`trySuccessorCandidates` / `handleSuccessorCandidateKey` 等）として実装。`successorEligible` フラグで確定直後の 1 打目を捕捉し、`leftSideContext` 末尾の名詞抽出（`extractNounFromContext`）でセッションをまたいだ文脈も活用。候補は `content_bigram` → `history` の順で優先。

**不採用の理由**:

- **UX とタイピングが合わない**: 組成前に英字を打ってモードに入るという設計が、日本語入力のリズムと相性が悪い。ユーザーが意識しないと恩恵を受けられない
- **学習データの問題**: `content_bigram` は `count >= 2`（同一ペアを 2 回以上確定）かつ Apple Intelligence 必須のため、使い始めはほぼ空振りになる
- **名詞抽出の精度が低い**: `extractNounFromContext` は Unicode 範囲チェックのみで、助詞が直後にある場合に誤抽出することがある
- **ローマ字 2 打目で体験が断絶**: 2 打目で仮名が確定した瞬間に通常組成へフォールバックするため、恩恵を受けられるのが実質 1 打目のみになる

**方針転換**: content-bigram のデータは保持したまま、Successor モードは削除。bigram を通常変換の候補ランキングに統合する方向で再設計する予定だったが、実 DB を確認したところデータが蓄積されていないことが判明し、テーブルごと廃止した（[F-2](#f-2-content_bigram-noun-bigram-テーブルの廃止2026-05-25) 参照）。

---

## F-2 content_bigram（noun-bigram）テーブルの廃止（2026-05-25）

**概要**: `content_bigram` テーブルは (prev_word, input_reading, output) のトリプルを記録し、`count >= 2` のペアを通常変換の候補ランキングに反映する設計だった。F-1 Successor モードのデータ基盤として導入。`NounBigramViewController` でデバッグ UI から蓄積状況を確認できるようにした。

**試みたこと**: `POSCommitSequencer` が Apple Intelligence の POS 分類結果を使い、content word（名詞・固有名詞）の確定時に bigram を記録。`fetchContentBigram` でクエリして変換候補の優先順位に加える実装。

**不採用の理由**:

- **データが蓄積されない**: 実 DB を確認したところ 49 件全件で count=1。同一 (prev, reading, output) トリプルを 2 回以上確定することは日常的な日本語入力では極めてまれであり、`count >= 2` の閾値を満たすレコードが実質ゼロ
- **設計前提が崩れた**: F-1 Successor モード削除後、bigram の用途は「候補ランキング補正」のみになったが、データが空のため効果もゼロ
- **sessionTextBuffer で代替**: leftSideContext を強化する `sessionTextBuffer`（PLAN260525）により、文脈依存の同音異義語 disambiguation は Zenzai に委ねられる。bigram による独自ランキングの必要性がなくなった

**判断**: `content_bigram` テーブル・`POSCommitSequencer`・`NounBigramViewController` をすべて削除（commit `5edf2bc`）。POS 分類自体（`LLMPOSClassifier`）はひらがな優先機能で引き続き使用するため維持。

> 関連: [F-1 Successor モード](#f-1-successor-モード後続語サジェスト2026-05-25)、[PLAN260525](../plans/PLAN260525.md)

---

## E-2 AzooKey needTypoCorrection による typo 許容変換（2026-05-06）

**概要**: `ConvertRequestOptions.needTypoCorrection = true` を設定することで、AzooKey のラティス探索に `TypoCorrectionGenerator` を追加し、読み入力の typo を補正した変換候補を出す。

**調査した内容**:
- `ConvertRequestOptions` に `needTypoCorrection: Bool?` が存在し、macOS では `nil` のとき `false` にフォールバックする（iOS は `true`）
- `TypoCorrectionGenerator` が扱う誤り訂正は「清音↔濁音の混同」のみ（シ→ジ、テ→デ、ハ→バ/パ 等）。キーボード上の隣接キー誤打（`kanzi` → `kanji` 等）はスコープ外
- 補正候補にはペナルティ −3.5〜−7.0 が付加される。`N_best=10` の制約下では、正規の読みの候補が豊富にある単語（「かんし」→34件）では補正候補がラティスから押し出されて出現しない
- サンドボックスで複数パターンを実測したが、typo 補正候補が上位に出るケースは確認できなかった

**不採用の理由**: AzooKey の `needTypoCorrection` は iOS フリック入力の「濁点ボタン押し忘れ」向けであり、ローマ字経由のひらがな direct 入力では恩恵が薄い。補正対象が狭く、ペナルティ設計上 N_best=10 では候補に現れないため実質効果ゼロ。`needTypoCorrection` を `true` にしても体感変化なし。ロールバック済み。

---

## 数字キー（1–9）による候補直接確定

**概要**: 候補ウィンドウ表示中に 1–9 を押すと対応する候補を確定する。

**不採用の理由**: 候補ウィンドウが履歴ヒットで自動表示される仕様のため、数字の連続入力（"123" など）で 3 文字目が候補選択として誤作動する。ASCII 組成中は無効にする回避策も試みたが、体験が悪いと判断して廃止。

---

## E-1 Backspace 再変換（2026-04-29）

**概要**: 確定直後に Backspace を押すと、確定テキストを読み（ひらがな）に戻してセグメント変換モードへ移行する。

**試みたこと**: IMK の `setMarkedText(_:selectionRange:replacementRange:)` で確定済みテキストをマークドテキストに置換する方式で実装し、動作することを確認した（`PLAN260429c.md` 参照）。

**不採用の理由**: 確定直後の Successor 候補表示（格助詞・bi-gram 予測）と競合する。候補を消そうとして押した Backspace が意図せず再変換を起動してしまい、操作感が悪い。確定後の自動候補表示を重視するこの IME の設計方針と根本的に相性が悪い。

> 関連: [PLAN260429c](../plans/PLAN260429c.md)

---

## A-3 句読点（。）での組成自動確定（2026-04-29）

**概要**: 組成中に `.`（→`。`）を入力したとき、組成を自動確定してから `。` を挿入する。Space+Enter の2打を省略する狙い。

**検討した設計**:
- AzooKey 先頭候補で自動変換 → ひらがな確定したい場合に意図しない漢字変換が起きる
- `commitComposition(candidate:)` 流用（選択候補があればそれ、なければひらがな） → 漢字にしたい場合は ↓+`.` が必要でキー数は変わらない

**不採用の理由**: `。` という1打に「変換したい」「ひらがなのまま」という2つの意図を区別する情報がない。どの設計でも一方のパターンが損をする。現状の Enter（ひらがな確定）/ Space+Enter（漢字確定）の使い分けが明示的で壊れにくく、代替する価値がない。

---

## D-1 pendingRomaji 先読みの2文字対応（2026-05-01）

**概要**: `buildPendingCandidateList` の先読みは `pendingRomaji.count == 1` のときのみ動作する。`sh` / `ch` / `ts` 等の2文字子音が pending の段階でも先読みを動かし、候補をより絞り込めるようにする。

**検討した変更**:
- `hasPendingPreview` の条件を `pending.count <= 2` に緩和
- `romajiToInitialKana` に `"sh": ["し", "しゃ", "しゅ", "しょ"]` 等の2文字キーを追加

**不採用の理由**: `romajiToInitialKana` には既に `"s": ["さ", "し", "す", "せ", "そ"]` が含まれており、`s` 1打の時点で「し」行を含む先読みが動作している。`sh` を追加しても先読みの有無は変わらず、候補の絞り込み精度が多少上がるだけで実用的な価値がない。`si` でも `shi` でも「し」に変換できるため、「`sh` pending の先読みが動かない」こと自体がユーザーの困りごとにならない。

---

## D-2 文頭フレーズ候補（SENTENCE_START bigram）（2026-05-01）

**概要**: `sentenceTerminators`（。！？\n）確定後は `committedHistory.removeAll()` で `lastCommittedOutput = nil` になり bigram が動かない。`"__START__"` という特殊な prev を bigram テーブルに記録することで、文頭でもよく使うフレーズを候補に出す。

**不採用の理由**: `recordPrefixes` が機能しているため、過去に確定した長いフレーズはその前方一致パターンが `history` テーブルに記録されている。文頭で「よ」と打てば `fetchHistoryPrefix` が「よろしくお願いします」を既に拾ってくる。bigram を追加しても「候補が出るかどうか」は変わらず、文脈依存のランキング調整にしかならない。現状の history prefix 検索で実質カバー済み。

---

## C-1 セグメントモード内の読み修正（2026-04-30）

**概要**: セグメントモード中にフォーカス文節の読みを Backspace で削って打ち直せるようにする。例: `いし → 意思` に変換されたが `いす → 椅子` に修正したい場合、セグメントモードを抜けずに読みを編集する。

**検討した設計**:
- **案1（Backspace でサブモード遷移）**: Backspace 押下でフォーカス文節の reading を `composedHiragana` に移し「読み編集サブモード」へ。文字キーも読みに追加される。Tab/Enter/←/→ で確定して通常セグメント選択に戻る。`SegmentState` に `isReadingEdit` フラグを追加する必要あり。
- **案2（F6 でトリガー）**: セグメントモード中の F6 で読み編集モードへ。Backspace の挙動を変えない。キーバインドが非自明。
- **案3（Backspace で reading を1文字削って次文節に渡す）**: Shift+← と実質同じ効果のため独立した価値がない。

**不採用の理由**: A-3（句読点自動確定）と同じ構造の問題——「1キーで複数の意図を区別できない」——を内包する。案1は Backspace の既存挙動（セグメント解除）を変更するため驚きが大きい。案2はキーが非自明。いずれの案も現状の「Escape → 組成に戻って打ち直し」と比べて複雑さに見合う改善が得られない。
