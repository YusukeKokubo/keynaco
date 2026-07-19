---
status: implemented
created: 2026-06-17
related_commit: 336efdf
---

# PLAN260617c: 打鍵レイテンシログの永続化

**クローズ（2026-07-19、PLAN260719 triage）**: `latency_log.jsonl` として実装・稼働済み（`336efdf` 以降 `42a7a73`・`ed25fec`・`46f4d12`・`360a5d0` で拡張）。`/keynaco-latency-profiler` と perf-cycle 全 plan の計測基盤になっとる。draft のまま status 更新が漏れとっただけ。

## 目的

`TypingLatencyStats` の集計結果をセッションごとにファイルへ追記し、施策の before/after 比較と長期傾向の把握を可能にする。

## 背景

PLAN260617b で実装した `TypingLatencyStats` はメモリ上の集計のみで、再起動するたびにリセットされる。「Branch 3–4 を削除した前後でキャッシュミス率が変わったか」「debounce を調整した効果はあったか」という比較が現状できない。

蓄積データがあれば:
- 施策前後で p95 fetch 時間やキャッシュミス率を数値で比較できる
- LLM にログを渡して「どの変更が体感に影響を与えたか」を分析させられる
- 「感覚でコスパが悪そう」ではなく「この条件のときだけ遅い」という具体的な問いを立てられる

## 設計

### ログフォーマット（JSON Lines）

1行 = 1セッション（フラッシュ1回）。

```json
{"ts": 1750123456, "version": "0.9.1", "label": "before-branch-removal", "cache_exact": 312, "cache_prefix": 45, "cache_miss": 28, "total_peeks": 385, "fetch_p50_ms": 42.3, "fetch_p95_ms": 187.1}
{"ts": 1750209856, "version": "0.9.2", "label": null, "cache_exact": 398, "cache_prefix": 41, "cache_miss": 19, "total_peeks": 458, "fetch_p50_ms": 38.1, "fetch_p95_ms": 142.6}
```

- `ts`: Unix タイムスタンプ（秒）
- `version`: `Bundle.main` の `CFBundleShortVersionString`
- `label`: 任意タグ（before/after 比較用。debug socket で設定）
- `total_peeks`: `cache_exact + cache_prefix + cache_miss`（セッション活動量の指標）
- その他は既存 `Snapshot` のフィールドをそのまま使う

### ファイルパス

`~/Library/Application Support/keynaco/latency_log.jsonl`

`DatabaseManager` と同じディレクトリ。既存の `applicationSupportDirectory` 解決パターンを流用する。

### フラッシュタイミング

`deactivateServer` は頻繁に呼ばれるため全回フラッシュしない。以下の条件を両方満たしたときのみ追記する。

- `total_peeks >= 20`（測定データが少なすぎるセッションを除外）
- 前回フラッシュから 5 分以上経過（短時間の切り替えで重複しない）

フラッシュ後は `latencyStats.reset()` を呼んで次セッションのカウントを 0 から始める。

### label の設定

debug socket で任意タグを付けられるようにする。施策前後にタグを打つことで後から比較できる。

```json
{"set_latency_label": "before-debounce-change"}
{"set_latency_label": null}
```

label は `TypingLatencyStats` か `AzooKeyConverter` に `var currentLabel: String?` として持たせる。

**label のライフサイクル**: label は `{"set_latency_label": null}` を明示的に送るまで維持する（flush 成功時・`reset()` 呼び出し時にはクリアしない）。before/after 比較では複数セッションにまたがって同じ label を使うため、明示的に消すまで残っていることが必要。

## 実装範囲

### Core（`TypingLatencyStats.swift`）

- `var currentLabel: String?` を追加
- `appendToLog(fileURL: URL, appVersion: String)` — フラッシュ条件チェック + JSONL 1行追記 + `reset()`
- フラッシュ条件チェック用に `var lastFlushedAt: Date?` と `var totalPeeks: Int`（`cacheExact + cachePrefix + cacheMiss`）を管理

### app 層（`InputController.swift`）

- `deactivateServer` 内で `latencyStats.appendToLog(fileURL: logFileURL, appVersion: ...)` を呼ぶ
- `logFileURL` は `DatabaseManager` の appSupport dir と同じ場所に解決

### debug socket（`DebugSocketServer+Commands.swift`）

- `{"set_latency_label": "..."}` コマンドで `latencyStats.currentLabel` を更新
- `{"read_latency_log": true}` コマンドで直近 20 行を返す（LLM 分析用）

## ファイル vs SQLite の判断

SQLite（`DatabaseManager` に追加）ではなく JSONL ファイルを選ぶ理由:

- **LLM への渡しやすさ**: JSONL は Read ツールやデバッグソケットの `read_latency_log` でそのまま貼り付けられる。SQLite は直接読めないため tooling が一枚増える
- **append-only の性質**: セッションごとに1行追記するだけで更新・削除が不要。SQL の得意なパターンではなく、むしろファイルの方が自然
- **既存 DB との分離**: `DatabaseManager` は history / user dict という「ユーザーが意図的に作ったデータ」を保持する。観測用数値を混ぜるとスキーマ変更時に巻き込まれるリスクがある

SQLite が有利になるのは「数百セッション分を複雑な条件でクエリしたい」場面だが、before/after 比較が主用途であれば数十行の JSONL を LLM に渡す方が速い。今の用途規模では SQLite は過剰。

## 既存コードの活用

| 既存コード | 活用方法 |
|-----------|---------|
| `TypingLatencyStats` | `appendToLog` メソッドを追加するだけ。集計ロジックは変更なし |
| `Snapshot.asDictionary()` | そのまま JSON シリアライズに使う |
| debug socket `stats` コマンド | `set_latency_label` / `read_latency_log` を同じ dispatch に追加 |
| `deactivateServer` | フラッシュ呼び出し先として使う |

## この機能で何を見るか

before/after 比較の具体例:

```
施策: Zenzai inferenceLimit を 5→3 に変更
label "before": fetch_p95_ms = 187ms, cache_miss = 7.3%
label "after":  fetch_p95_ms = 112ms, cache_miss = 7.1%
→ キャッシュミス率は変わらず、fetch 時間が短縮 → 施策有効
```

長期傾向の例:

```
2週間分のログを LLM に渡す
→「cache_miss 率が水曜午後に高い傾向がある（左文脈が切り替わるアプリを使う時間帯）」
→「fetch_p95 が特定の version から上昇している」
```

## 関連

- 前提実装: [PLAN260617b-typing-latency-measurement.md](PLAN260617b-typing-latency-measurement.md)
- ログは `~/Library/Application Support/keynaco/latency_log.jsonl` に蓄積。`cleanup_history_db.py` 同様に手動でローテートする運用を想定
