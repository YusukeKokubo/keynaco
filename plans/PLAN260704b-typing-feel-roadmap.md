---
status: in-progress
created: 2026-07-04
---

# PLAN260704b: 打鍵体感改善ロードマップ

実測ログ（latency 229 セッション・input 1308 確定・divergence 149 件）とパイプライン実装調査を突き合わせて出した、打鍵体感改善の施策候補一覧。**このファイルはロードマップ（親 plan）**。各施策に着手するときは `/keynaco-perf-cycle` で `objective_axis` を 1 つに絞った個別 plan（`PLAN2607xx-<slug>.md`）を切り、このファイルの進捗表を更新する。

第 2 弾（2026-07-10 再計測に基づく履歴学習系の施策）: [PLAN260710-typing-feel-learning-gaps.md](PLAN260710-typing-feel-learning-gaps.md)

## 実装状況

| 施策 | 優先 | 状態 | 個別 plan |
|------|------|------|-----------|
| A1 peek パスの同期 lcid 変換排除 | 1 | 完了 | PLAN260617 相当 |
| A2 Zenzai 推論の段階化（typing 軽 / pause 濃） | 2 | 完了 | — |
| B1 数字・日付読みの Z1 カタカナ偏向対策 | 3 | 完了 | — |
| A3 ロック取得後 generation 再チェック | 4 | 完了 | — |
| A4 短読み pinned cache + LRU 拡大 | 5 | 完了 | — |
| B2 dateTime source のカバレッジ拡大 | 6 | 完了 | — |
| C1 whileTyping 常時 rich=true の見直し | POC | 現状維持 | POC260704c（delta -11%） |
| C2 Phase B/C lcid 取得の局所化 | A1 同時 | 不要 | PLAN260613 で B/C 削除済み |

## 背景：診断結果（2026-07-04 計測）

体感を削っとるのは変換精度ではない（1 位確定率 82.5%、passive 素通し確定 92%）。犯人は尾っぽ側の 4 つ:

1. **peek パスに紛れ込んだ同期変換**（peek_update p50 2.5ms に対し p95 42ms）
2. **打鍵中も全 fetch がフル Zenzai 推論**（fetch_complete_p95 ≥ 300ms がセッションの 20.5%）
3. **破棄される推論が LockedConverter を塞ぐ queue 詰まり**（lock_wait max 819ms。「こうこく」7 秒事故の直接原因: 直前の wasted fetch「こうこ」1159ms がロックを占有）
4. **数字・日付候補の探し回り**（pain 34 件の最大クラスタ。3〜7 秒級が 9 件。Z1 が「6ガツ」「2020ネン」等カタカナ偏向）

### ベースライン数値（all-time 229 セッション / pain は直近 7 日）

| 指標 | 値 |
|---|---|
| fetch p50 / p95 | 97.8ms / 183.8ms（セッション avg） |
| fetch_complete p50 / p95 | 205.0ms / 260.9ms |
| fetch_complete - fetch（実効 debounce 待ち） | median 112.7ms |
| peek_update p50 / p95 | 2.8ms / 49.2ms（max 1063ms） |
| lock_wait p95 | avg 24.2ms（max 858ms） |
| キャッシュ exact / prefix / miss | 9.7% / 47.0% / 43.3% |
| 2 文字読みミス | 率 87.1%・件数 821（全ミス 1297 の 63%） |
| wasted fetch | all-time 30.5% / 直近 7 日 17.4% |
| fetch_complete_p95 ≥ 300ms セッション | 47/229（20.5%） |
| 1 位確定率 / explicit 確定率 | 82.5% / 8% |
| pain ケース（BS≥2 or scroll>0 or >3s） | 34/208（16.3%、直近 7 日） |
| divergence 真の UX 損失 / 救済 | 70 / 79（救済内訳: history 59・dict 14・fixed 6） |

## 施策 A: 処理そのものの見直し

### A1. peek パスから同期 lcid 変換を追い出す（本命）

**問題**: 打鍵中の候補更新（peek）で prefix focus の品詞判定が走り、DB に lcid が無いと `PrefixFocusPolicy.rank`（`PrefixFocusPolicy.swift:37-43`）が `azooKey.lcidForCommitted`（`AzooKeyConverter.swift:357-366`）を呼ぶ。これは**メインスレッド上で converter のロックを取り辞書変換を同期実行**する。候補数ぶん複数回発生し得る。裏で Zenzai 推論がロックを握っとると打鍵ごと固まる。peek_update p95 tail の最有力仮説（PLAN260622 の bisect が abandoned になった後、コード調査で特定した経路）。

**対策**: peek 時は lcid 不明なら保守的既定（prefix focus を通す/通さないの既定側）で即返し、分類は `AzooKeyPOSBackfill` の非同期バックフィルに任せる。挙動差は初出語の初回 peek のみ。

**検証指標**: peek_update p95、lock_wait p95。objective_axis: latency。

### A2. Zenzai 推論の段階化（typing 中は軽く、手が止まったら濃く）

**問題**: `makeOptions`（`AzooKeyConverter.swift:245-261`）は読み長・タイミングで分岐せず、全 fetch が `inferenceLimit=5` のフル推論。だが確定の 92% は passive 素通しで、打鍵中 fetch の仕事は暫定表示の質の維持。

**対策**: fetch 呼び出し単位で inferenceLimit をパラメタ化。whileTyping は 1〜2、pause 検知（inter-key ≥160ms）・explicit・Space warm はフル（5）。

**検証指標**: fetch p50/p95、lock_wait p95、divergence UX 損失数（精度劣化の見張り。暫定表示の Z1 品質が下がりすぎたら閾値を戻す）。objective_axis: latency。

### A3. ロック取得後の generation 再チェック

**問題**: 進行中の Zenzai 推論に中断機構は無い（キャンセルが効くのは debounce sleep 中と detached 実行前のチェックまで、`AzooKeyAsyncScheduler.swift:84-94`）。generation 照合は `withLock` の**外**で行われるため、ロック待ち行列に並んだ stale fetch は数百 ms 待った後に無駄な推論を完走し、次を待たせる。

**対策**: `AzooKeyConverter.requestCandidates`（`AzooKeyConverter.swift:199-230`）の `withLock` 突入直後に generation を再照合し、古ければ変換せず即返す。LockedConverter の設計自体（PLAN260704 で「健全・触らない」と判断済み）は変えない。

**検証指標**: lock_wait p95、wasted fetch のうち fetch 実行まで進んだ件数。objective_axis: latency。

### A4. 短読み（≤2 文字）pinned cache + LRU 拡大

**問題**: キャッシュミス 1297 件中 821 件（63%）が 2 文字読み。「して」「では」「けど」等の頻出短読みが毎セッション初回ミスになる。LRU 上限は 50 件（`AzooKeyConverter.swift:39`）で evict も早い。

**対策**: ≤2 文字読みは既にキャッシュキーから leftSideContext を除外しとる（`AzooKeyConverter.swift:56`、= 文脈非依存と設計上認めとる）ため、頻出短読みの候補列を起動時プリロードまたは LRU とは別枠の pinned 領域に置く。あわせて LRU 上限を 200 程度へ。

**検証指標**: cache exact 率、2 文字読みミス件数、fetch 発火数。objective_axis: CPU-waste。

## 施策 B: 体感的に打鍵を妨げない見直し

### B1. 数字・日付読みの Z1 カタカナ偏向対策

**問題**: pain 最大クラスタ。「6がつ」→ Z1「6ガツ」、「2020ねん」→「2020ネン」で、正解（6月・2020年）到達まで 3〜7 秒の候補探しが 9 件。divergence の真の UX 損失 70 件にも同型が並ぶ。

**対策**: 数字を含む読みで Zenzai のカタカナ翻字候補を減点、または number/dateTime source（`CandidateScoreBuilder`）のスコアを数字始まり読みで引き上げる。スコアリング層で閉じる。

**検証指標**: 数字含み読みの pain 件数、divergence UX 損失のうち数字・日付型の件数、selection_depth。objective_axis: UX-pain。

### B2. dateTime source のカバレッジ拡大

**問題**: 「ついたち→1日」「なながつ→7月」等、和語読み⇔数字表記の日付ゆらぎで待たされとる。エンジンではなく日付候補生成のカバレッジの問題。

**対策**: dateTime source に和語読み（ついたち・ふつか・なながつ等）→ 数字表記の対応を追加。

**検証指標**: 日付読みの pain 件数・composition_ms。objective_axis: UX-pain。

## 施策 C: コスパ見直し枠

### C1. whileTyping 非同期 fetch の常時 rich=true を問い直す（POC 先行）

**問題**: 非同期 schedule は常に `richCandidates: true`（`AzooKeyAsyncScheduler.swift:98`）。狙いは Space 押下時の rich キャッシュヒットだが、explicit 確定は 8% しかなく、表示側 `filterCandidatesForDisplay` は予測補完を落としとる。92% の打鍵のために毎回 rich 推論を払っとる可能性。

**POC**: rich / 非 rich の fetch コスト差を実測。差が大きければ「whileTyping は非 rich、`warmRichCacheForExplicit`（Space keyDown 時）だけ rich」へ。キャッシュキーが rich フラグ込み（`AzooKeyConverter.swift:57`）のため、統一すれば二重 fetch の解消効果もある。peek の照合キー（rich:true、`InputHandler+Candidates.swift:33`）も揃えて変える必要がある点に注意。

**判断基準**: コスト差が fetch p50 の 20% 未満なら現状維持で close。

**POC 結果（2026-07-04、`AzooKeyRichCostHostedTests`、Zenzai on・inferenceLimit=2）**:

| 条件 | p50 | p95 | mean |
|------|-----|-----|------|
| rich=false | 42.3ms | 133.8ms | 50.0ms |
| rich=true | 37.6ms | 101.7ms | 43.7ms |

delta p50 = **-11.0%**（rich の方が速い）。20% 閾値未満 → **現状維持**。whileTyping の `richCandidates: true` は変更不要。

### C2. Phase B/C lcid 取得の局所化（A1 と同時実施）

PLAN260613 Phase B/C の技術評価（メモリ project_lcid_phase_bc_eval）で「常時コスト付きのレアパス。残すならコスト局所化が筋」と確定済み。削る/残すの product 判断は保留のまま、「epsilon 帯の行だけ lcid を引く」局所化を A1 の作業と同時にやる。

## やらないこと

- **debounce の再チューニング**: 70ms 化はロック直列化で fetch_complete_p95 を悪化させた反証済み（`AzooKeyDebouncePolicy.swift:19-25` コメント）。短読み 120ms 化（PLAN260621）で wasted fetch は 35%→17% まで改善済み。
- **次読みの投機的 prefetch**: converter が単一ロック直列の現状では推論を増やす方向で queue 詰まりを悪化させる。A2/A3 完了後に再評価。
- **長い予測候補の深掘り対策**（「どう」→「どうにかしたい」scroll 44 の件）: 事例 1 件のみ。意図的な履歴掘りの可能性が高く、データが溜まるまで様子見。

## 運用

- 着手順の推奨: A1 → A2 → B1 → A3（体感インパクト ÷ 実装コスト順）。A1 と C2 は同一箇所のため同時。
- 各施策は着手時に `/keynaco-perf-cycle` で個別 plan を切り、`objective_axis`・`baseline_at`・`sample_threshold` を契約として固定する（本ファイルのベースラインは計画時点のスナップショットであり、個別 plan は着手時点で取り直す）。
- 個別 plan が implemented / abandoned になったら本ファイルの進捗表を更新。全行が終端になったら本ファイルを implemented にする。

## 実装後の検証（未了）

コード変更は 2026-07-04 にマージ済み（`deef0b9`–`9d61d2d`）。`/keynaco-perf-cycle` の検証ゲート（セッション ≥5・確定 ≥100）は実ログ再計測待ち。

**直近 1h スナップショット（2026-07-04 15:00、n=7 セッション・30 確定）** — サンプル不足のため断定不可:

| 指標 | ベースライン | 直近 1h |
|------|-------------|---------|
| peek_update p95 | 49.2ms | 50.2ms |
| lock_wait p95 | 24.2ms (max 858) | 9.5ms (max 66.8) |
| pain 率 | 16.3% | 0% (0/30) |
| wasted fetch | 17.4% | 24–28% |

**A1 後続（2026-07-04）**: ユーザー辞書登録時に `schedulePOSClassification` + `upsertPOSClassification` で pos/lcid を書き込み（履歴未確定語の prefix focus 退行を解消）。
