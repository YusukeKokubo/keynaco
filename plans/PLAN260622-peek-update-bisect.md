---
status: in-progress
created: 2026-06-22
objective_axis: latency
baseline_at: 2026-06-22T17:51:00
baseline_window: 24h
sample_threshold:
  sessions: 5
  confirmations: 100
---

# PLAN260622: peek_update p95 tail の bisect 計測

## 目的軸（1 行）

レイテンシ削減（主要指標: `fetch_complete p50/p95`、`peek_update p95`、副次: `lock_wait p95`）。

## 背景：1 サイクル目を「観測強化」に振る理由

`/keynaco-perf-cycle` のサイクル文化を回す上で、最初に当てた仮説候補（debounce policy 緩和・short read 120ms 縛り解除）は、コードコメント `AzooKeyDebouncePolicy.swift:22-25` で **既に反証検証済み**だった。「70ms にすると LockedConverter で直列化された fetch が queue 詰まりして fetch_complete_p95 を悪化させとった」「short read 120ms は wasted fetch 35% の主要因に対処した結果」。つまり debounce policy は既に十分チューニングされとる。

ここで残る可変要素は **`peek_update` p95 tail spike**。median 2ms に対し p95 39ms、max 282ms。140 倍の差は構造的（メモリ allocator・GC・OS scheduling）ではなく、特定のコードパスが時々重い可能性が高い。だが現状の計装では peek_update は 1 つのブラックボックス値しか取れず、**どのサブステップが tail を支配するか判定できん**。

この 1 サイクルは「次サイクルで何を削るか確定するための観測強化」に振る。直接の数値改善は狙わず、**「次サイクルの仮説を根拠ある形にする」のが成果物**。

## ベースライン数値（直近 24h、セッション数 72）

| 指標 | 値 |
|---|---|
| fetch p50 / p95 | 113.9ms / 208.7ms |
| **fetch_complete p50 / p95** | **214.5ms / 318.1ms** |
| fetch_complete - fetch (実効 debounce 待ち) | median 106.8ms |
| **peek_update p50 / p95** | **2.0ms / 39.4ms (max 282.9ms)** |
| lock_wait p50 / p95 | 0ms / 24.5ms (max 532ms) |
| キャッシュ exact / prefix / miss | 7.2% / 47.8% / 45.0% |
| wasted_fetch | 422/1118 (37.7%) |
| fetch_complete p95 ≥ 300ms | 43/72 セッション (59.7%) |
| 1 位確定率 | 87.2% |

出典: `/tmp/perf-cycle/PLAN260622-latency-baseline-analyze.txt`、`/tmp/perf-cycle/PLAN260622-latency-baseline-pain.txt`。

## 仮説

### 観測

- `peek_update` の median 2ms と max 282ms の差は 140 倍。median と p95 の差も約 20 倍。
- pain ケース（composition_ms > 3000ms）が全体の 12.8%。長読み・複合語で詰まっとる傾向。
- `peek_update` の中身は現状ブラックボックス。`handler.handle` 全体 + `applyCandidateWindowEffects` + `adapter` (IMK 越境)を含む（`InputController.swift:233`）。

### 仮説

`peek_update` の p95 tail spike の主因は次のいずれか。

| 候補 | 想定根拠 | 構造的 / 可変 |
|---|---|---|
| A) `peekCachedCandidates` LRU 走査 | キャッシュ 50 件の prefix 走査 O(n) | 可変（データ構造変更） |
| B) `collectCheapCandidateSources` 履歴 DB 読み | SQLite LIKE クエリの再ロード | 可変（クエリ最適化） |
| C) `makeCandidateListSources` 統合処理 | フィルタ・dedup・ソートの組み合わせ | 可変（アルゴリズム） |
| D) `applyCandidateWindowEffects` NSWindow update | テーブル view リロード、位置計算 | 可変（UI 更新ロジック） |
| E) `adapter.insertText` IMK 越境 | Electron 等で遅い IPC 待ち | アプリ依存（可変は限定的） |

### 予測

bisect 計測後、各サブステップの p95 を比較したとき：
- A〜C が支配的（≥10ms in p95）なら → keynaco 内部のアルゴリズム改善で攻める
- D が支配的なら → 候補ウィンドウの描画最適化
- E が支配的なら → ターゲットアプリ別の指標（バンドル ID 単位）に分けて報告する必要あり

外れ値（max 282ms）の主因はサンプル数が少ないため、直接特定できないかもしれん。p95 の主因が分かれば max は副次的に下がる。

### 副次効果の予想

- ログ 1 件あたりのサイズ微増（サブステップ 4-5 field 追加）。input_log は確定単位なので、現状の `composition_ms` 計測には影響しない。
- 計装オーバーヘッドは `ContinuousClock.now` 数回で <1µs/key 想定。median 2ms は変わらん見込み。

## 構造的 vs 可変の判定

> **構造的**: peek_update p50 = 2ms はこれ以上下げられん（最低限の I/O とロジック）
>
> **可変**: peek_update p95 = 39ms ＆ max 282ms ← この差を作っとるサブステップは可変な余地が大きい

bisect 計測で「どのサブステップが tail を作っとるか」が分かれば、次サイクルで攻める対象が確定する。

## 実装方針

`KeydownLatencySignpost` に enum で識別したサブステップ計測点を追加し、`TypingLatencyStats` で配列に貯める。

### 計測点（4 箇所）

1. **handle (state 更新 + 候補決定)**: `handler.handle(...)` の前後。peekCachedCandidates + collectCheap + makeCandidateList が全部入る
2. **window apply**: `applyCandidateWindowEffects(action:adapter:)` の前後（`InputController.swift:231`）
3. **insertText IMK**: `adapter.didInsertText` トリガで挿入 API 呼び出しの前後（`AdapterCoordinator` 側）
4. **left context resolve**: `LeftContextSource.resolveProduction` の前後（実際は signpost 開始前だが、参考値として計測）

### 出力

`latency_log.jsonl` のセッション集計に以下を追加：
- `peek_handle_p50_ms` / `peek_handle_p95_ms`
- `peek_window_apply_p50_ms` / `peek_window_apply_p95_ms`
- `peek_insert_text_p50_ms` / `peek_insert_text_p95_ms`
- `peek_left_context_p50_ms` / `peek_left_context_p95_ms`

`analyze.py` も「peek_update サブステップ別 p95」セクションを追加する（後続コミットでも可）。

### 変更ファイル（想定）

| ファイル | 内容 |
|---|---|
| `Core/Sources/Core/TypingLatencyStats.swift` | サブステップ別ローリング配列 + serialize に追加 |
| `keynaco/KeydownLatencySignpost.swift` | サブステップ enum + begin/end API |
| `keynaco/InputController.swift` | 計測点 3 箇所の呼び出し追加 |
| `.claude/skills/keynaco-latency-profiler/scripts/analyze.py` | サブステップ p95 セクションを追加（次サイクルで参照） |

不変条件：既存の `peek_update_*_ms` / `fetch_complete_*_ms` は変えない（baseline 数値の継続性のため）。

## 検証ゲート

- サンプル閾値: セッション数 ≥ 5 AND 確定数 ≥ 100
- 計測 window: Step 2 と同じ "24h"
- 比較対象指標:
  - 既存指標（`peek_update p50/p95`、`fetch_complete p50/p95`）が**有意に動かない**こと（計装オーバーヘッドが許容範囲内）
  - 新規サブステップ指標が全セッションで欠損なく出力されること
  - tail spike（p95 ≥ 20ms のセッション）でサブステップの p95 主因が判定できること

サンプル不足の場合は `status: in-progress` のまま保留。`status: implemented` を付けるのはゲート通過後のみ。

## 進捗（status: in-progress 中）

- 2026-06-22T18:23: ベースライン計測完了（24h、72 セッション）
- 2026-06-22T18:23: 実装完了（`TypingLatencyStats` サブステップ配列 + `KeydownLatencySignpost` の `SubStep` enum + `InputController.runKeyDown` 4 計測点）
- 2026-06-22T18:23: `./scripts/test_core.sh` 524 件全通過、`xcodebuild build` SUCCEEDED 確認

## 残課題（検証ゲート通過待ち）

1. `/deploy` で実機反映
2. 24h 以上の通常打鍵でログ蓄積（サンプル閾値: セッション数 ≥ 5 AND 確定数 ≥ 100）
3. `python3 .claude/skills/keynaco-latency-profiler/scripts/analyze.py --ts-start <verified_at - 86400>` で再計測
4. **計装オーバーヘッドの確認**: 既存指標 `peek_update_p50_ms` / `peek_update_p95_ms` がベースライン（2.0ms / 39.4ms）から大きく動いとらんことを確認
5. **新規指標の出力確認**: `peek_handle_p50_ms` / `peek_apply_effects_p50_ms` / `peek_window_apply_p50_ms` / `peek_left_context_p50_ms` が全セッションに出とるか
6. tail spike セッション（peek_update_p95_ms ≥ 20ms）で主因サブステップを特定

ゲート通過後に `status: implemented` に更新し、サブステップ別 p95 の Before/After 表をここに追記する。

## 結果（status: implemented で追記）

未計測。
