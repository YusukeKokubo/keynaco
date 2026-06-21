---
name: keynaco-perf-cycle
description: keynaco のパフォーマンス・打鍵体感改善を「観測 → 仮説 → 実装 → 検証 → 記録」の 1 サイクルとして駆動するスキル。plan を**ベースライン計測の段階で draft として作成**し、目的軸とベースライン数値を契約として固定してから実装に進むのが要点。`/keynaco-latency-profiler` を内部で呼ぶ。「パフォーマンス改善したい」「打鍵体感を良くしたい」「ログ見て改善案出して実装まで」「レイテンシ下げたい」「wasted fetch 減らしたい」「pain ケースを減らしたい」と言われたとき、またはコード変更とログ分析を 1 セッションで往復したいときに積極的に使う。最初に目的軸を宣言させ、サンプル数が足りないと plan の `status: implemented` を付けさせない検証ゲートを持つ。
---

# keynaco-perf-cycle

keynaco の差別化軸は「打鍵体感」だから、パフォーマンス改善は単発の最適化じゃなくて反復するサイクルになる。このスキルは 1 サイクルを最後まで通すための足場で、**判断軸の言語化** と **検証の対称性** を強制する。

## なぜ「plan 後追い」じゃなく「plan 先行」か

最初は実装後に plan を書く運用にしとった（PLAN260621 がその例）。問題が 2 つ出た：

1. **目的軸が暗黙になる**。「一番効果が高い施策」と言うても、CPU 無駄削減 / UX pain 削減 / レイテンシ / 精度のどれを最大化するかで打ち手は変わる。後から書くと、結果に合う軸を選びがちで自己欺瞞になる
2. **before/after が非対称になる**。後追いだと「24 時間 vs 15 分」みたいに window の幅が違うまま比較してしまい、ノイズと効果の区別が甘くなる

plan を draft として **計測の段階で書く** と、目的軸とベースライン数値とサンプル window が契約として固定される。実装後に出る数字が嘘をつけなくなる。

## サイクル全体像（順番厳守）

| Step | やること | 出力 |
|---|---|---|
| 1 | **目的軸を宣言**（CPU 無駄 / UX pain / レイテンシ / 精度のどれか 1 つ） | 1 行宣言 |
| 2 | **ベースライン計測**（`/keynaco-latency-profiler` を呼ぶ） | analyze + pain_analysis の出力をファイルに保存 |
| 3 | **plan を draft で作成**（目的軸 + ベースライン数値 + 仮説 + 構造的/可変判定） | `plans/PLANYYMMDD-*.md`、`status: draft` |
| 4 | **実装**（plan の仮説に沿って局所修正） | commit |
| 5 | **検証**（Step 2 と**同じクエリ・同じ window 幅**で再計測） | After 数値 |
| 6 | **検証ゲート**（サンプル不足なら `status: in-progress` のまま） | plan を更新 |
| 7 | **plan を implemented に更新**（After 表 + `related_commit` 追記） | 確定 |

各ステップで「次に進んでええか」を口に出して確認すること。サイレントに飛ばすのが一番危ない。

## Step 1: 目的軸の宣言（必須）

最初に必ずユーザーに 1 行で書かせる。これが書けんままサイクルに入らん。

| 目的軸 | 主要指標 | 典型施策 |
|---|---|---|
| **CPU 無駄削減** | `wasted_fetch %`、`lock_wait p95` | debounce 調整、キャッシュ戦略、prefetch 制御 |
| **UX pain 削減** | `BS≥2 件数`、`scroll_count > 0`、`composition_ms p95` | 候補順位、履歴重み、prefix focus 閾値 |
| **レイテンシ削減** | `fetch_complete p50/p95`、`peek_update p95` | キャッシュキー、debounce、Zenzai 推論制限 |
| **精度改善** | `first_candidate_rate`、`divergence rescued_by=null 件数` | Zenzai profile、履歴スコア、品詞重み |

**1 サイクルで複数軸を狙わん**。混ぜると「何が効いたか」が分からんようになる。副次効果として他軸が動くのは構わんが、最大化対象は 1 つだけ。

`docs/concept.md` の「打鍵体感」とポジショニング基準もここで読み返す。短期の CPU 削減のために打鍵体感を犠牲にしとらんかは常に問う。

## Step 2: ベースライン計測

`/keynaco-latency-profiler` を呼ぶ。そのスキルが 3 ログ（latency / input / divergence）の読み分けを既に強制しとるで、ここは委譲する。

ただし **このスキル特有の追加要件** が 3 つある：

1. **`--since` の window 幅を Step 3 で再利用する前提で固定する**。「直近 24h」と決めたら検証時も「直近 24h」（=実装後に 24h 待つ）。「直近 1h」なら 1h 使う前で打ち切らん。サンプル少なくても対称性が優先
2. **出力をファイル保存**：`/tmp/perf-cycle-<plan-id>-baseline.txt` に `analyze.py` と `pain_analysis.py` の出力を残す（Claude のセッション外でも追跡できるように）
3. **計測時刻を ISO8601 で記録**：plan の冒頭に `baseline_at: 2026-MM-DDTHH:MM:SS` を残す

`docs/retrospectives.md` の「ログのフラグと UX 損失を混同しない」を読み返す。`divergence_log` の `rescued_by` が非 null は救われた成功で UX 損失ではない。

## Step 3: plan を draft で作成（このサイクルの核）

`plans/PLAN<YYMMDD>[-letter]-<slug>.md` を作る。命名規約と frontmatter は
`.claude/skills/plans-audit/references/plan-frontmatter.md` 参照（拡張フィールド
`objective_axis` / `baseline_at` / `baseline_window` / `sample_threshold` / `verified_*`
の正本もそこにある）。

**ここでの plan は契約書**。Step 4 以降に進む前に、frontmatter の必須フィールド
（`status: draft`、`created`、`objective_axis`、`baseline_at`、`baseline_window`、
`sample_threshold`）を全部埋める。`objective_axis` の取り得る値は `CPU-waste` /
`UX-pain` / `latency` / `accuracy` のいずれか 1 つ（Step 1 で宣言したやつ）。

本文は以下のセクション必須：

### 1. 目的軸（1 行）

何を最大化するか。Step 1 の宣言をそのまま貼る。

### 2. ベースライン数値（表）

主要指標を表で。`/tmp/perf-cycle-*-baseline.txt` から抜く。

### 3. 仮説

「なぜこの数値が出とるか」「何を変えると動くと予測するか」。次の構造を入れる：

- **観測**: ログから読めた事実
- **仮説**: 根本原因の推定
- **予測**: 実装後にどの指標がどう動くか（数値レンジ）
- **副次効果の予想**: 他指標がどう動きうるか

### 4. 構造的 vs 可変の判定

実装に進む前に必ず判定する。**間違えるとサイクル全体が無駄になる**。

> **構造的**: 入力データの分布や物理（打鍵速度・読みの長さ）から決まり、コード変更では動かせん指標
>
> **可変**: ポリシー・パラメータ・アルゴリズムで動かせる指標

**例（PLAN260621 から）**:
- 「2 文字読みのキャッシュミス率 90%」は**構造的**。各単語の初出 2 文字は新規だから、キャッシュサイズを増やしても劇的には下がらん
- 「wasted fetch 35%」は**可変**。debounce policy が読み長を見とらんだけで、policy に読み長を渡せば下がる

仮説が「構造的な指標を動かそう」としとったらここで止める。可変な代替指標を探す。

### 5. 実装方針

何のコードをどう変えるか、要点だけ。詳細は commit に書く。

### 6. 検証ゲート（このセクション必須）

```markdown
## 検証ゲート

- サンプル閾値: セッション数 ≥ 5 AND 確定数 ≥ 100
- 計測 window: Step 2 と同じ "24h"
- 比較対象指標: <step 2 で固定した主要指標>

サンプル不足の場合は `status: in-progress` のまま保留。`status: implemented` を付けるのはゲート通過後のみ。
```

## Step 4: 実装

plan の「実装方針」に沿って局所修正。スコープを広げん（一般エンジニアリングルールと同じ）。

commit メッセージに plan ID（例: `PLAN260621`）を入れると後で追跡しやすい。必須じゃないが推奨。

## Step 5: 検証（同一クエリ・同一 window）

`/keynaco-latency-profiler` を再度呼ぶ。**Step 2 と完全に同じ引数**を使う：

```bash
# baseline と同じ window
python3 .claude/skills/keynaco-latency-profiler/scripts/analyze.py --since 24h
python3 .claude/skills/keynaco-latency-profiler/scripts/pain_analysis.py --since 24h
```

短い window（例: 1h）にしたい衝動が出るが、対称性を優先する。「24h 待つ間どうするか」は別タスクとして並行で動かせばええ。

出力を `/tmp/perf-cycle-<plan-id>-after.txt` に保存。

## Step 6: 検証ゲート

plan 冒頭の `sample_threshold` と after 計測のセッション数・確定数を比較。

- **閾値未達** → plan を `status: in-progress` のまま据え置く。本文に「現時点の after 計測（n=X、未満）: ...」を追記して、後日再計測する旨を残す
- **閾値到達** → Step 7 へ

サンプルが薄いときに「とりあえず effects observed」みたいに implemented を付けるのが一番後悔する。**サンプルが揃うまで待てる仕組みがこのスキルの一番の価値**。

## Step 7: plan を implemented に更新

frontmatter を `status: implemented` に変え、`verified_at` / `verified_window` /
`verified_sample` / `related_commit` を追記する（フィールド仕様は plans-audit の
plan-frontmatter.md 参照）。

**契約違反チェック**: `verified_window` は `baseline_window` と同一値であるべき。
違うなら Step 5 をやり直す（同じ window で取り直す）。

本文に **Before / After 表** を追加：

```markdown
## 結果

| 指標 | Before | After | 評価 |
|---|---|---|---|
| ... | ... | ... | ... |

副次効果:
- ...

残課題（このプランの範囲外）:
- ...（次サイクルの起点になる）
```

副次効果の事前予測（Step 3 の「副次効果の予想」）が当たったかも書く。当たっとると次サイクルの仮説精度が上がる。

## アンチパターン（過去の失敗から）

1. **後追い plan**: 実装してから plan を書く。目的軸が暗黙になる。PLAN260621 がこの例（このスキルを作る動機になった）
2. **非対称比較**: 24h ベースライン vs 15 分 after で「効いた」と判定する。短期サンプルはノイズで動くので断定できん
3. **構造的指標を狙う施策**: 「2 文字読みのミス率 90% を下げる」型。本質的に下げられん指標に時間を使う
4. **複数軸の同時最大化**: 「CPU 削減と pain 削減を両方やる」。どっちが効いたか分からん
5. **検証ゲート無視**: n=3 で `status: implemented` を付ける。後で読み返したとき「実証された施策」として誤読される

## 関連スキル

- `/keynaco-latency-profiler` — このスキルがログ計測のために呼ぶ下位スキル。Step 2 と Step 5 で使う
- `/plans-audit` — plan のライフサイクル可視化。サイクル後の棚卸しで使う
- `/poc-first` — まだ仮説が固まっとらん（POC が要る）段階のときはこっちが先

## 既存 plan の活用

PLAN260621 がこのスキルが想定するワークフローの **後追いケーススタディ** として読める。同じ題材を「plan 先行」でやり直すとどうなるかをイメージするとサイクルが具体的になる。
