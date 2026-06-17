---
name: keynaco-latency-profiler
description: keynaco の latency_log.jsonl を読んでパフォーマンスを分析し、ボトルネックと改善アクションを提案するスキル。「ログ分析して」「パフォーマンス確認して」「レイテンシ見て」「キャッシュの状況は？」「最近遅くない？」「Zenzai重い気がする」「ミス率どう？」のように言われたとき、またはパフォーマンス改善の文脈が出てきたときに積極的に使う。
---

# keynaco レイテンシプロファイリング

## ログの場所と形式

```
~/Library/Application Support/keynaco/latency_log.jsonl
```

JSONL 形式（1行1セッション）。セッションは「5確定以上 + 5分インターバル」でフラッシュされる。短いセッション（アプリ非アクティブ時の強制フラッシュ）はサンプル数が少ないため、解釈時に注意する。

## 分析の進め方

まず `scripts/analyze.py` を実行して全体像を把握する。スクリプトは以下を出力する：

```bash
python3 .claude/skills/keynaco-latency-profiler/scripts/analyze.py
```

出力が得られたら、下記「指標の読み方」と「よくあるパターン」を参照しながら解釈する。数字だけ出して終わりにせず、「何が問題か」「次に何をすべきか」まで伝える。

## 指標の読み方

### レイテンシ系

| 指標 | 意味 |
|------|------|
| `fetch_p50_ms` / `fetch_p95_ms` | AzooKey + Zenzai の変換処理時間（debounce 待ちを含まない） |
| `fetch_complete_p50_ms` / `fetch_complete_p95_ms` | キー入力から候補表示まで（debounce 込みの体感レイテンシ） |
| `peek_update_p50_ms` / `peek_update_p95_ms` | キャッシュ参照・候補更新の時間（通常 1〜5ms） |
| `inter_key_p50_ms` | 打鍵間隔の中央値（ユーザーの入力速度） |
| `debounce_policy_p50_ms` | debounce の設定値（実測値ではない） |

`fetch_complete - fetch` の差 ≈ 実効 debounce 待ち時間。`inter_key_p50` より debounce 設定が大きいと無駄な待ちが生じる。

### キャッシュ系

| 指標 | 意味 |
|------|------|
| `cache_exact` | 完全一致キャッシュヒット数 |
| `cache_prefix` | より短い読みのキャッシュを暫定表示に流用した数 |
| `cache_miss` | キャッシュなし（実 AzooKey 呼び出し） |
| `miss_rate_by_reading_len` | 読み長別ミス率（比率） |
| `miss_count_by_reading_len` | 読み長別ミス件数（絶対値）。miss_rate と合わせて見る |
| `fetch_p95_by_reading_len` | 読み長別 fetch p95。Zenzai 外れ値が特定の読み長に偏るか確認できる |

キャッシュキーは `(reading, leftSideContext, richCandidates)` の組み合わせ。2文字以下の読みは leftSideContext を無視するよう修正済み（2026-06 以降のビルド）。

### 選択行動系

| 指標 | 意味 |
|------|------|
| `first_candidate_rate` | 1位候補をそのまま確定した割合（高いほど変換精度がよい） |
| `selection_depth_p50` / `p95` | 何番目の候補を選んだか。p95 が大きいと下位候補を掘っている |
| `candidate_confirmations` | 候補ウィンドウ表示中に確定した回数 |

## よくあるパターンと対処

### パターン1: 2文字読みのミス率が高い（> 80%）
旧ビルドのキャッシュキーに leftSideContext が含まれていたことによる構造的問題。2026-06 以降のビルドで修正済み。修正後も高い場合はキャッシュ eviction が多い可能性（上限 50 件）。

### パターン2: fetch_complete_p95 が 300ms 超のセッションが多い（> 20%）
Zenzai 推論の外れ値が原因の可能性が高い。`fetch_p95_by_reading_len` を確認する。特定の読み長に偏っていれば Zenzai の処理量が問題。ランダムならスレッドスケジューリングや llama_context の競合を疑う。

### パターン3: fetch_complete - fetch が debounce 設定より大幅に大きい
非同期パイプラインのオーバーヘッドが大きい。`inter_key_p50` と `debounce_policy_p50` の関係を確認する。

### パターン4: first_candidate_rate が低い（< 0.5）
変換精度の問題。Zenzai 設定・履歴の蓄積状況・ユーザー辞書を確認する。

## 仮説が出たら次のステップ

- **キャッシュ挙動の検証** → `/keynaco-ime-sandbox` で `peekCachedCandidates` の実挙動を確認
- **コードレベルの原因** → `AzooKeyConverter.swift`（キャッシュキー・LRU）、`TypingLatencyStats.swift`（計測ロジック）
- **修正後の効果確認** → `/deploy` → 実使用 → 再分析（次のログフラッシュまで待つ）

## 注意点

- Instruments プロファイリングは IME では実用的でない（フォーカスが奪われる）。このログが唯一の実測手段。
- セッション数が少ない（< 20）と p95 が不安定。「傾向はあるが断定できない」と添えること。
- `fetch_p95_by_reading_len` は 1 セッション内のサンプル数が少ないことがある。複数セッションを集計してから判断する。
