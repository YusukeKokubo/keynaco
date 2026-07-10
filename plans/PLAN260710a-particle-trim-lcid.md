---
status: draft
created: 2026-07-10
objective_axis: UX-pain
baseline_at: 2026-07-10T20:14:30+0900
baseline_window: 14d
sample_threshold:
  sessions: 5
  confirmations: 100
related_plan: PLAN260710-typing-feel-learning-gaps.md
---

# PLAN260710a: 助詞トリムの lcid 判定化（D1）

親: [PLAN260710](PLAN260710-typing-feel-learning-gaps.md) 施策 D1。

## 1. 目的軸

**UX-pain 削減** — 「とくに」型（副詞末尾がたまたま助詞文字）の scroll / pain を減らし、完成形履歴行が育つようにする。

## 2. ベースライン数値（14d、2026-07-10T20:14:30+0900）

保存: `/tmp/perf-cycle-PLAN260710a-baseline.txt`

| 指標 | 値 |
|------|-----|
| セッション | 1935 |
| 確定 | 8266 |
| pain 全体 | 810 / 8266（9.8%） |
| とくに | n=8 / pain=6 / scroll_sum=6（確定は「特に」6・「特になし」2。pain は全部 scroll=1 + explicit） |
| いまは | n=11 / pain=9 / scroll_sum=19（D2 対象。D1 では直らんが副作用観察用） |
| ちゃんと | n=4 / pain=3 / scroll_sum=3 |
| history `とく→特` | count=31（壊れ行） |
| history `とくに→特に` | **不在**（`とくになし` のみ） |
| history `いまは→今は` | count=0 |

比較対象の主要指標（検証ゲート用）:

1. `とくに` の pain 件数・scroll_sum
2. history DB に `とくに→特に` 行が生えるか（count ≥ 1、理想は確定回数に追従）
3. 副次: pain 全体率（悪化してないこと）

## 3. 仮説

- **観測**: `trimTrailingParticle` が文字列サフィックスだけで「特に」→「特」に壊し、`とく→特` だけが育つ。`LIKE 'とくに%'` は `とく` にヒットしないため、完成形は履歴に永遠に出ない。ユーザーは毎回 Space→scroll=1 で「特に」を拾う
- **仮説**: 末尾セグメントが本当に joshi のときだけ trim すれば、「特に」は完成形のまま記録され、2〜3 回の確定後に row 0 直行になる
- **予測（14d after）**: `とくに` pain ≤ 2（理想 0）、scroll_sum ≤ 2。`とくに→特に` が history に存在し count が確定回数に近い
- **副次効果の予想**: azooKey 以外の確定では trim が走らなくなるため、真の助詞付き（「東京が」等）も完成形行が育ち始める（D2 二重記録の部分先行）。「いまは」pain が自然減する可能性あり。レイテンシは不変想定

## 4. 構造的 vs 可変

| 指標 | 判定 | 理由 |
|------|------|------|
| `とくに` の scroll/pain | **可変** | 学習キーが壊れているのが原因。判定を直せば完成形が育つ |
| 「特に」を打つ頻度そのもの | 構造的 | ユーザーの語彙分布。触らない |
| 既存 `とく→特` count=31 | 可変だが本 plan 外 | cleanup は必須ゲートではない（完成形 exact は壊れ行にブロックされない） |

## 5. 実装方針

### 5.0 POC ゲート（実装前必須） — **通過（2026-07-10）**

実辞書 slow テスト `ParticleTrimSegmentPOCTests` の結果:

| reading | text | segments | wouldTrim (count≥2 ∧ last joshi) |
|---------|------|----------|----------------------------------|
| とくに | 特に | 1: 特に lcid=1281 | false |
| おもに | 主に | 1: 主に lcid=1287（rcid のみ joshi） | false |
| いっしょに | 一緒に | 1: 一緒に lcid=1288 | false |
| いまは | 今は | 1: 今は lcid=1314（rcid のみ joshi） | false |
| とうきょうまで | 東京まで | 2: 東京 + まで(joshi) | true |

結論: **本線の判定条件で進んでよい。** 「特に」型は単一セグメントなので誤トリムしない。真の多セグメント助詞（東京まで）だけ trim する。「今は」も辞書 1 見出しのため trim せず、azooKey 確定では完成形が育つ（D2 部分先行が POC でも裏付け）。

注意: `rcid` が joshi でも `lcid` が非 joshi・単一セグメントの語がある（主に・今は）。**判定は lcid + count≥2 に固定**（rcid 単体では副詞を壊す）。

- [x] POC ゲート: セグメント構成確認（上記）
- [ ] `AzooKeyCandidate` に末尾セグメント joshi flag を追加し、`displayCandidates` で設定、CandidateContext 経由で `commitComposition` まで運ぶ
- [ ] `recordPrefixes` を「trim してよいか」を呼び出し側から受け取る形にし、flag 無しはトリムしない
- [ ] `trimTrailingParticle` の文字列サフィックス自動判定を廃止
- [ ] 回帰テスト（fast: stub flag / slow: POC 固定）

### 5.1 本体

1. `displayCandidates` で `data.count >= 2 && CIDData.isJoshi(cid: data.last!.lcid)` を `AzooKeyCandidate` に載せる（`shouldTrimTrailingJoshi` と同条件）
2. `ScoredCandidate` / `CandidateSession` / `CandidateContext` で選択行の flag を確定まで運ぶ（追加ロックなし）
3. `recordPrefixes(reading:output:trimTrailingParticle:)` — `true` のときだけ末尾助詞文字列を trim。省略/`false` は trim しない
4. 文字列版の自動判定 `trimTrailingParticle(_:)` は廃止。`trailingParticles` は trim 実行時の削り文字列用に残す
5. 回帰: fast は stub flag、slow は POC 固定（既存 `ParticleTrimSegmentPOCTests`）

## 6. 検証ゲート

- サンプル閾値: セッション数 ≥ 5 AND 確定数 ≥ 100（全体）。加えて対象 reading `とくに` の確定が after window に ≥ 3 あること（少なすぎると判定不能）
- 計測 window: baseline と同じ **14d**
- 比較対象指標: 上記「とくに pain / scroll_sum / history 完成形行」
- 成功基準: `とくに` pain が明確減（目安: pain 率 6/8 → ≤25%）かつ `とくに→特に` が history に存在

サンプル不足の場合は `status: in-progress` のまま保留。`status: implemented` はゲート通過後のみ。

## やらないこと

- 助動詞レンジまでの trim
- 文字列サフィックス fallback
- commit 時の同期 lcid 取得
- 既存壊れ行の自動 cleanup（別 triage）
- D2 / E1 の実装
