---
status: draft
created: 2026-07-06
---

# PLAN260706: ゼロベース土台リファクタリング — 打鍵同期パスの契約化と変換パイプライン再設計

機能拡張のためではなく、**打鍵体感を改善する伸びしろを作る**ためのリファクタリング計画。ロジックを単純にし、毎打鍵の処理コスト構造そのものを軽くする。2026-07-06 のコードベース全域調査（打鍵同期パス / 非同期変換パイプライン / 候補構築・スコアリングの 3 方向）と直近 48h の実測ログに基づく。

## 位置づけ（先行 plan との関係）

- **PLAN260704**（implemented）: 挙動不変の構造整理。dead code・コピペ・状態の単一正本化・KeyEventPipeline・KeyDispatchMode まで完了。
- **PLAN260704b**（in-progress）: 実測ベースの点対策。A1–A4・B1–B2 実装済み、検証ゲート待ち。
- **本 plan**: その次の層。**挙動を変えてでも**ロジックを単純化し、処理コストの構造を変える。PLAN260704b が「やらないこと」に入れた施策（debounce 再チューニング・投機 prefetch）は、単一ロック直列 converter という**構造制約が理由**で封じられとる。本 plan の狙いはその制約自体を外し、次の体感改善の選択肢を解禁することにある。

## 現状の実測（2026-07-06、直近 48h・76 セッション）

| 指標 | 値 | 読み解き |
|------|-----|---------|
| lock_wait p95 | avg 3.1ms（max 82.7ms） | A3 でほぼ解消（旧 max 858ms）。queue 詰まりは沈静化 |
| fetch p50 / p95 | 92.6ms / 151.5ms | A2 段階化後。推論自体は既に軽い側 |
| fetch_complete p50 | 212.3ms | **体感レイテンシの主成分が交代**: ≈ debounce 待ち 125ms + fetch 92ms。いま最大の単一成分は推論ではなく「待ち」 |
| peek_update p50 / p95 | 2.6ms / 43.4ms | A1 後も p95 tail が残存。同期パスにまだ重い経路がある |
| キャッシュ exact/prefix/miss | 9.8% / 42.1% / 48.1% | 2 文字読みミス率 88.7%（167 件）。A4 pinned の効果が出とるか要検証 |
| wasted fetch | 27.9% | 打鍵中 fetch の 4 本に 1 本が捨てられとる |
| fetch_complete_p95 ≥ 300ms | 21.1% | ベースライン 20.5% から不変 |
| pain 率 | 15.9%（38/239） | 数字・日付系が依然最大クラスタ |

**B1/B2 は対策不足が確定**: B1/B2 込みビルド（7/4 15:07 デプロイ・稼働確認済み）の後も「7がつ→7月 3.7s」「2020にち→2020日 3.8s」等が発生しとる。数字・日付の pain は本 plan のスコープ外だが、PLAN260704b 側で B1 の効き方（スコア優先は上がったが到達時間が縮まん理由）を別途検証する必要がある。

## 調査で確定した構造事実

### A. 打鍵同期パス — 毎打鍵で走る不要コスト

候補ビルドが走る打鍵（2 モーラ目以降の母音打鍵）1 回の同期処理に、以下が載っとる:

1. **prefix focus が候補ごとに DB クエリ**: `prefixFocusFilteredSources`（`InputHandler+Candidates.swift:420-441`）が prefix 候補 N 件それぞれに `lcidForOutput` → miss なら `posForOutput` と、**最大 2N 本の `dbQueue.sync`** を発行する（`PrefixFocusPolicy.swift:26,30`）。pos/lcid は打鍵中に不変のデータ。
2. **1 打鍵で候補ビルドが実質 2 回**: 同期 peek ビルドと、非同期 AzooKey 到着時の `.inject` ビルドが**同じ `collectLocalCandidateSources`（DB 3 クエリ）を二度実行**する（`InputHandler+Candidates.swift:45-55,96-104,151-189`）。履歴・辞書は打鍵中に変わらんのに 2 回引いとる。
3. **DB read が書き込みと同一シリアルキュー**: `dbQueue`（qos .utility 単一キュー、`DatabaseManager.swift:9`）を履歴 record・POS upsert・penalize の非同期書き込みと共有。確定直後の打鍵 read は書き込みの後ろで待つ。1 ビルド 3 hop あるので待ち機会も 3 倍。
4. **非日付読みでも `Calendar.current` + `Date()` を毎ビルド生成**（`InputHandler+DateTime.swift:9-40`）。
5. **`NSWorkspace.frontmostApplication` を毎打鍵問い合わせ**（`InputController.swift:260`、日記ログ用 bundleID）。`selectedRange()` の IMK IPC も毎打鍵（`:261-265`）。
6. **dedup が二重**: `CandidateScoreBuilder.build` の辞書 dedup の直後に `CandidateScoredLayout.assemble` がもう一度 Set dedup（`CandidateScoredLayout.swift:21-23`）。
7. **peek の prefix 探索が線形走査**: `candidateCacheKeys` 最大 200 件を逆順走査し、各キーで文字列を再構築して比較（`AzooKeyConverter.swift:168-184`）。

なお prepared statement は全打鍵系クエリで再利用されとり（`cachedStmt`）、SQLite 1 本あたりは速い。問題はクエリの**本数と hop 回数**。

### B. 非同期変換パイプライン — 複雑さの根と構造限界

1. **llama 推論に中断機構がない**（`zenzai.swift:100-162`、キャンセルフック 0 件）。キャンセルが効くのは debounce sleep 中・detached 突入前・ロック取得直後（A3）の 3 点で、すべて**推論開始前**。ロックを塞いどる当人の推論は止められん。これが「debounce を短くすると詰まる」反証（70ms 化失敗）の根。
2. **世代管理が 4 変数 + 二重 NSLock + 一致判定 4 回**: `candidateGeneration` / `liveGeneration`（専用 NSLock ミラー） / `genSnapshot` / 引数コピー、判定は schedule 内 3 箇所 + `AsyncCandidateArrival.shouldApply`（`AzooKeyAsyncScheduler.swift:21-22,88,101,120` / `AsyncCandidateArrival.swift:32`）。
3. **キャッシュ辞書がロック外 read**: `candidateCache` を MainActor の peek（`AzooKeyConverter.swift:150-187`）と detached fetch の write（`:259`）が並走し得る。`@unchecked Sendable` 頼みの潜在データ競合。
4. **キャッシュを迂回する同期変換経路が残存**: `fetchAzooKeyCandidates` の非 explicit rich=false（キー不一致で二重 fetch 誘発、`InputHandler+Candidates.swift:197`）、`lcidForCommitted` / `canonicalReading` の非キャッシュ baseOptions 直行（`AzooKeyConverter.swift:375-403`）。
5. **AzooKey の増分変換機構が未使用**: converter は前回 lattice の差分利用（`kana2lattice_no_change`）を持つが、keynaco は毎回新規 `ComposingText` を作るため 1 文字追加ごとに全 lattice 再構築（`AzooKeyConverter.swift:230-231`）。
6. **確定学習後もキャッシュ非無効化**: 学習 commit がキャッシュ済み候補列に反映されん。

### C. 候補構築・スコアリング — 「単純な原則 + 特例の山」

1. **単一スコア空間の上に promote/demote 特例が 3 層**: 履歴スコアの AzooKey rank0 超え底上げ（`CandidateScoreBuilder.swift:63-65`）、`.explicit` 限定の prefix 拡張強制下位（`:166,220-224`）、hiraganaBonus の upsert 迂回直書き（`:118-133`）。「score でソートしとる」原則の意味を 3 箇所で上書きしとる。
2. **機能語 dismiss が 2 段**: pre-score（reading 判定）と post-score（row 0 テキスト判定）が同じ `isBuiltinFunctionalWord` を別々に使う（`InputHandler+Candidates.swift:221-223,265-266,323`）。
3. **数値↔読みの知識が 3 テーブルに逆方向で二重管理**: `NumericReadingExpander` の monthStem/dayReading と `InputHandler+DateTime` の monthReadingTable/dayReadingTable が同じ対応表を双方向に別実装。
4. **AzooKey 供給 3 経路・合流点 2 箇所**: fetchSync だけ `collectCandidateSources`、peek/inject は `assembleFromSources` と、合流点が割れとる。number/dateTime だけ収集段を通らず assemble 段で別生成（`:230-231`）。
5. **panelInteraction が 2 フィールド派生のまま**（`CandidateSession.swift:44-48`、enum 定義済みでフィールド化見送りの明記コメントあり）。
6. **composedHiragana への追記入口が 5 箇所**（`+NormalInput.swift:66,84,95,108,124`、addRomaji を経由せん直 `+=`）。
7. **候補構築系テスト 100+ 件が特例の回帰ガードの塊**（InputHandlerCandidatesTests 49 + CandidateScoreBuilderTests 22 + Snapshot 20 ほか）。特例を消す変更はテスト書き直しとセット。

## ゼロベースの設計像（到達点の契約）

ゼロから設計するなら守られとるはずの 3 つの契約に向けて収束させる。

**契約 1 — 打鍵同期パスは「ローマ字変換 + メモリ内参照 + marked text 同期」だけ。** DB クエリ 0 本、AppKit/IMK 問い合わせは組成開始時と確定時のみ。DB・推論由来の情報はすべて非同期到着分をメモ内スナップショットで参照する。効果目標: peek_update p95 を p50 と同桁（数 ms）へ。

**契約 2 — 変換リクエストは単一 actor の coalescing queue に入る。** 世代は投入時に振る 1 変数だけ。最新世代以外は**実行前に**捨てる。キャッシュも actor 内に隔離してロック外 read を消す。llama 推論の中断不能は変わらんが、「実行前に捨てる」判定が構造で保証されるので、debounce 短縮・投機 prefetch を安全に試せる土台になる。

**契約 3 — 候補の順序はスコアだけが決める。** promote/demote の後付け層を持たず、ソースごとのスコア関数が一つの単位系へ写像する。dismiss は 1 段。特例を足すときはスコア関数の中に書く（順序操作を外から重ねない）。

## Phase 分割

### Phase 1: 打鍵同期パスから DB・IPC を退避（挙動ほぼ不変・効果即時）

- [ ] `output → (pos, lcid)` のプロセス内メモ化で prefix focus の per-candidate クエリ（最大 2N 本）を撲滅する
- [ ] peek ビルドで取得したローカルソース（履歴・辞書）を async inject ビルドへ引き渡し、DB 3 クエリ × 2 回を × 1 回にする
- [ ] 残る 3 クエリを 1 回の `dbQueue.sync` に統合するか、read 専用コネクションを分離する（WAL は並行 read 可）。書き込みキューの後ろで打鍵 read が待つ構造を解消する
- [ ] `generateDateTimeCandidates` に早期ガードを入れ、`Calendar.current` / `Date()` 生成を日時読みマッチ時だけにする
- [ ] `NSWorkspace.frontmostApplication` の問い合わせを毎打鍵から activate 時・確定時へ移す
- [ ] dedup の二重（ScoreBuilder / ScoredLayout）を 1 パスに統合する

**検証**: peek_update p95・fetch_complete p50 の再計測、`test_core_all.sh` + sandbox 回帰 3 本。挙動差は「async 到着時のソース鮮度」境界のみ（確定直後の再組成で古い履歴が見える窓が生じんか sandbox で確認）。

### Phase 2: 変換パイプラインの actor 化（複雑さの返済 + 次の一手の解禁）

- [ ] `AzooKeyConverter` の変換・キャッシュを単一 actor（または単一直列 executor）に封じ、`LockedConverter` の NSLock・`liveGeneration` の第 2 NSLock・`abortBeforeFetch` クロージャ・手動 `Task.detached` 移送を廃止する
- [ ] 世代管理を「投入時比較 1 回」に集約し、4 変数・判定 4 回を解消する。wasted 判定の「空配列 = abort」という暗黙契約も明示的な結果型にする
- [ ] キャッシュ辞書のロック外 read（MainActor peek × detached write）を actor 隔離で構造的に消す
- [ ] 同期 fetch 経路の rich キーを統一し、`lcidForCommitted` / `canonicalReading` をキャッシュ経由にする（Phase 1 のメモ化と重なる部分は統合）
- [ ] 確定学習後にキャッシュを無効化（または該当読みだけ purge）する

**検証**: 挙動不変が原則。sandbox 回帰 3 本 + `/keynaco-ime-sandbox` で非同期到着タイミングの手動シナリオ。lock_wait・wasted fetch の再計測。Thread Sanitizer が回せるなら peek/fetch 並走の race 検査。

### Phase 3: スコアリングと dismiss の単純化（挙動を変える。テスト書き直し込み）

- [ ] promote/demote 3 層をスコア関数へ畳み込む。本丸は履歴底上げ（`historyDisplayScore`）の廃止で、履歴スコアと AzooKey スコアの単位系を最初から揃える設計に置き換える
- [ ] 機能語 dismiss を 1 段に統合する（pre/post どちらに寄せるかは concept 指針 1 の意図から決める）
- [ ] 数値↔読みテーブルを単一正本化する（`NumericReadingExpander` と `+DateTime` の対応表統合）
- [ ] AzooKey 供給 3 経路の合流点を 1 つにし、number/dateTime も収集段（`CandidateListSources`）へ載せる
- [ ] `panelInteraction` を enum 単一フィールド化する（PLAN260704 Phase 5 で見送った分）
- [ ] `composedHiragana` への追記入口 5 箇所を単一メソッド経由にする
- [ ] 影響するテストは「実装の選択肢」ではなく「ユーザー体感」をアサートする形に書き直す（retrospectives 準拠。特例を消すときは git log で由来を確認してから）

**検証**: before/after で divergence・input_log の pain を比較。sandbox で機能境界（hiraganaPreferred・機能語 dismiss・数字/日付・explicit demote）を一巡。候補順序が変わるので `/deploy` 後に数日の実使用観測を挟む。

### Phase 4: この土台の上で解禁される施策（本 plan のスコープ外・個別 plan で）

Phase 1–2 が終わると、これまで構造制約で封じられとった以下が試せるようになる。着手時は `/keynaco-perf-cycle` か poc-first で個別 plan を切る:

- **debounce 短縮の再挑戦**: 70ms 化の反証（PLAN260621 時点）は直列 converter でのロック詰まりが原因。coalescing queue 化後は前提が変わる。体感レイテンシ最大成分（待ち 125ms）への直接攻撃
- **増分 lattice（`kana2lattice_no_change`）活用 POC**: 1 文字追加時の全再構築をやめる。fetch p50 92ms の下げ余地
- **アイドル時の投機 prefetch**: `requestPostCompositionPredictionCandidates` は public API。pause 検知（inter-key ≥160ms）時に低優先で流す
- **prefix focus モーラ閾値表の簡素化 POC**: pos/lcid メモ化後に「閾値表がどれだけ効いとるか」を divergence/input_log で実測してから判断する

## やらないこと

- **llama 推論の中断機構の自作**: upstream（AzooKeyKanaKanjiConverter / llama.cpp）の領域。inferenceLimit 段階化（A2）で減衰済みとし、これ以上は追わん
- **エンジン層の変更・ビッグバン書き直し**: 各 Phase は独立にコミット・リリース可能で、途中で止めても資産が残る（PLAN260704 と同じ原則）
- **スコア定数の数値チューニング**: Phase 3 は構造の話。定数の最適値探しは個別 perf-cycle の管轄
- **数字・日付 pain の直接対策**: B1/B2 の検証・追加対策は PLAN260704b 側で追う

## リスクと対策

| リスク | 対策 |
|--------|------|
| Phase 3 で候補構築系テスト 100+ 件の書き直しが「バグ仕様の固着」を逆方向に踏む（正しい特例まで消す） | 特例ごとに git log で導入意図を確認 → ユーザー体感アサートで書き直し → sandbox 一巡。無言でテストを実装追従させない（retrospectives 準拠） |
| actor 化でタイミングが変わり sandbox でしか出んバグを生む | Phase 2 完了時に sandbox 回帰 3 本 + 非同期到着の手動シナリオ必須。ユニット全緑を根拠に skip しない |
| ソースメモ化の鮮度前提（打鍵中は履歴不変）が崩れる操作 | 確定 → 即再組成の境界を sandbox で確認。確定時にメモを invalidate する設計にする |
| read コネクション分離で WAL snapshot の古さを踏む | retrospectives「DB 直編集後の再起動」と同型の罠。分離後に書き込み→即 read の整合を sandbox で確認 |
| 同じ if 分岐に乗っとる明示意図ロジックの巻き込み（機能語 dismiss 統合時の hiraganaPreferred 等） | フォールバック撤廃の教訓どおり、機能境界を実機 sandbox で再点検 |

## 検証ゲート

各 Phase を `- [x]` で埋めても、以下が全部通るまで次 Phase に進まん:

1. `./scripts/test_core_all.sh` 緑
2. `xcodebuild test -scheme keynaco` 緑
3. sandbox 回帰 3 本（marked text / candidate cleanup / prefix focus）緑
4. `/deploy` → 実機で主要動線一巡（組成 → Space → 選択 → Enter、ブラケット、英数切替、Shift+Delete）
5. **latency 再計測**: Phase 1 後は peek_update p95、Phase 2 後は lock_wait・wasted fetch、Phase 3 後は divergence・pain 率。いずれもセッション ≥5・確定 ≥100 を待ってから判断する
