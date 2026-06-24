---
name: keynaco-latency-profiler
description: keynaco の latency_log.jsonl を読んでパフォーマンスを分析し、ボトルネックと改善アクションを提案するスキル。「ログ分析して」「パフォーマンス確認して」「レイテンシ見て」「キャッシュの状況は？」「最近遅くない？」「Zenzai重い気がする」「ミス率どう？」のように言われたとき、またはパフォーマンス改善の文脈が出てきたときに積極的に使う。
---

# keynaco レイテンシプロファイリング

## 結論を出す前に 3 ログ全部を読む

keynaco の `~/Library/Application Support/keynaco/` には 3 種類のログが並んでおり、性質が違う。**1 つだけで「IME のどこを直すべきか」を決めない**。詳しくは [`docs/retrospectives.md`](../../../docs/retrospectives.md) の「ログの『フラグ』と『UX 損失』を混同しない」を参照。

| ログ | 役割 | 単独で使うと… |
|------|------|------------------|
| `input_log.jsonl` | **UX 損失の真実**。`bs_count`・`scroll_count`・`composition_ms`・`was_explicit` で「ユーザーが困った確定」を直接観察 | これが「直すべき問題」抽出の起点 |
| `latency_log.jsonl` | 速度の指標（このスキルの本題） | 速度は分かるがユーザーが困ったかは分からん |
| `divergence_log.jsonl` | Zenzai Z1 がズレたフラグ | **UX 損失とは限らない**。`rescued_by` が非 null なら履歴/辞書が救った成功ケース |

**手順**:
1. `input_log.jsonl` で `bs_count >= 2` / `scroll_count > 0` / `composition_ms > 3000` を抽出 → 真の pain ケース一覧
2. `latency_log.jsonl` を本スキルのスクリプトで集計 → 速度ボトルネックの位置
3. `divergence_log.jsonl` を見るとき、`rescued_by` が入っとるエントリは UX 損失ではない（履歴/辞書が機能した証拠）。`rescued_by=null`（= `was_explicit=true`）だけが真の Zenzai 改善余地
4. **DB を直接書き換える前に必ず `sqlite3` で中身を SELECT する**（同 docs の retrospectives 参照）

**pain ケース・複合語・fetch lock_wait の統合分析**:

```bash
python3 .claude/skills/keynaco-latency-profiler/scripts/pain_analysis.py --since 30m
```

`input_log` + `divergence_log` + `fetch_log` を横断して：
- BS≥2 / scroll>0 / composition_ms>3000 の pain ケース一覧
- 🔗 マーク = 漢字 cluster ≥2 = 複合語の苦戦（Zenzai が複合語処理に弱いパターンの検出）
- pain と divergence の reading で join（「救:history」か「UX 損失」か）
- fetch_log の `lock_wait` 上位（reading 単位の queue 詰まり犯人特定）

**ワンライナー集**（直近のセッションで pain ケース・救われたケースを即時把握）:

```bash
# 直近 30 分の latency 集計
python3 .claude/skills/keynaco-latency-profiler/scripts/analyze.py --since 30m

# pain ケース（BS 多発 or 候補スクロール or 迷い時間長い）を直近 1 時間で抽出
python3 -c '
import json, time
since = (time.time() - 3600) * 1000
with open("'"$HOME"'/Library/Application Support/keynaco/input_log.jsonl") as f:
    for l in f:
        r = json.loads(l)
        if r["ts"] < since: continue
        if r.get("bs_count",0) >= 2 or r.get("scroll_count",0) > 0 or r["composition_ms"] > 3000:
            print(f"bs={r.get(\"bs_count\",0)} scroll={r.get(\"scroll_count\",0)} ms={r[\"composition_ms\"]:5d} '\''{r[\"reading\"]}'\'' -> '\''{r.get(\"committed\")}'\''")
'

# divergence を「真の UX 損失」と「履歴/辞書が救った」に分けて表示
python3 -c '
import json, time
since = (time.time() - 3600) * 1000
with open("'"$HOME"'/Library/Application Support/keynaco/divergence_log.jsonl") as f:
    rows = [json.loads(l) for l in f if json.loads(l).get("ts",0) >= since]
loss = [r for r in rows if not r.get("rescued_by")]
rescued = [r for r in rows if r.get("rescued_by")]
print(f"真の UX 損失: {len(loss)} 件  救われた: {len(rescued)} 件")
for r in loss:
    print(f"  [UX損失] {r[\"reading\"]:12s} Z1={r.get(\"z1\",\"\"):15s} -> {r[\"confirmed\"]}")
'
```

新しいログには `ts_iso`（ISO8601 文字列）も併記されとるため、`ts` の単位（latency=秒・input/divergence=ms）を読み違える事故は防止される。

## ログの場所と形式

```
~/Library/Application Support/keynaco/latency_log.jsonl
```

JSONL 形式（1行1セッション）。セッションは「5確定以上 + 5分インターバル」でフラッシュされる。短いセッション（アプリ非アクティブ時の強制フラッシュ）はサンプル数が少ないため、解釈時に注意する。

## 分析の進め方

まず `.claude/skills/keynaco-latency-profiler/scripts/analyze.py` を実行して全体像を把握する。スクリプトは以下を出力する：

```bash
# 全セッション集計
python3 .claude/skills/keynaco-latency-profiler/scripts/analyze.py

# バージョン別比較（リリース前後の確認に使う）
python3 .claude/skills/keynaco-latency-profiler/scripts/analyze.py --by-version

# 日付範囲で絞り込む（ts は Unix timestamp）
python3 .claude/skills/keynaco-latency-profiler/scripts/analyze.py --ts-start 1781708400 --ts-end 1781794799

# 絞り込み＋バージョン別を組み合わせる
python3 .claude/skills/keynaco-latency-profiler/scripts/analyze.py --ts-start 1781708400 --by-version
```

`ts` フィールドは Unix timestamp（秒）。日付から変換する場合:
```python
import datetime
d = datetime.date(2026, 6, 18)
start = int(datetime.datetime(d.year, d.month, d.day).timestamp())
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
