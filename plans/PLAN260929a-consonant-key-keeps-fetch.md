---
status: in-progress
created: 2026-09-29
objective_axis: latency
baseline_at: 2026-09-29T17:03:00
baseline_window: 7d
sample_threshold:
  sessions: 100
  confirmations: 500
---

# PLAN260929a: 読みが変わらんキーで whileTyping fetch を捨てず、debounce を詰める

## 1. 目的軸

レイテンシ削減。打鍵から whileTyping 候補が出るまでの時間（`fetch_complete` p50/p95）を下げる。

## 2. ベースライン数値（直近 7d、2026-09-29 17:03 JST 計測）

生出力は `/tmp/perf-cycle-PLAN260929a-baseline.txt`（analyze.py と pain_analysis.py を `--since 7d` で実行）。

| 指標 | 値 |
|---|---|
| セッション数 / 確定数 | 525 / 2031 |
| fetch_complete p50（セッション median） | 226.5ms |
| fetch_complete p95（セッション median） | 279.7ms |
| fetch_complete p95 ≥ 300ms のセッション | 213/525（40.6%） |
| fetch p50 / p95（セッション median） | 119.8ms / 192.8ms |
| fetch_complete − fetch（実効 debounce 待ち、median） | 111.3ms |
| debounce policy（median） | 105ms |
| inter_key p50（median） | 128.4ms |
| lock_wait p95（セッション median / fetch_log 全体 p95） | 0ms / 26ms |
| wasted fetch（latency_log 合計） | 1364/3464（39.4%） |
| peek_update p95（median） | 42.8ms |

体感レイテンシの約半分（111ms）が debounce 待ちで、残りが fetch 本体。fetch 本体は W35〜W39 を通して p50 100〜110ms で安定しとり、読み長にもほぼ依存しない（2 文字でも p50 約 100ms）。

## 3. 仮説

**観測**

- `InputController.runKeyDown` は keyDown ごとに `AzooKeyAsyncScheduler.onKeyDown` を呼び、世代を必ず 1 つ進めて pending タスクをキャンセルする。子音キー（`k` など、かな読みが変わらんキー）でも同じ。
- ローマ字入力では読みが変わるのは母音キーだけで、次に読みが変わるのは通常 2 打鍵先（inter_key p50 128ms なら約 260ms 先）。ところが現状は間の子音キーで、debounce 中のタスクは消え、走行中の fetch は結果を捨てられる（`wastedAfterFetch`）。
- debounce（90〜120ms）+ fetch（約 110ms）≈ 200〜230ms は 1 打鍵間隔（128ms）より長いで、母音キーで予約した fetch はほぼ必ず次の子音キーに潰される。wasted 39% の大部分はこの経路と推定。
- 結果の適用側は `AsyncCandidateArrival.shouldApply` で「`composedHiragana == reading`」を見とるで、読みが変わっとらん限り古い結果を貼る危険はない。世代一致の条件が子音キーに対しては過剰な安全策になっとる。

**仮説**

debounce を長めに取っとる理由（wasted 削減）は、子音キーが fetch を捨てる挙動と打ち消し合っとる。読みが変わらんキーで pending/走行中の fetch を生かせば、debounce を詰めても wasted は増えず、fetch_complete が縮む。

**予測**

- fetch_complete p50: 226ms → 160〜190ms
- fetch_complete p95: 280ms → 230〜260ms
- fetch_complete p95 ≥ 300ms のセッション比率: 40.6% → 30% 未満

**副次効果の予想**

- wasted fetch %: 下がる（子音キー起因の破棄がなくなる）。debounce 短縮で上がる分と相殺して 25〜35% 程度
- lock_wait p95: 若干上がりうる（fetch 開始が早まり、次の母音キーの fetch と重なる）。30ms を超えたら要注意
- fetch 本体 p50: 変化なし（本プランでは触らない）

## 4. 構造的 vs 可変の判定

- **debounce 待ち（111ms）は可変**。`AzooKeyDebouncePolicy` の値と、子音キーで世代を進めるかどうかのポリシーで決まる
- **子音キー起因の wasted は可変**。世代を進める条件の問題
- **fetch 本体の約 110ms は現時点では判定保留**。POC260704c のホスト実測（p50 約 40ms）と本番値（約 110ms）に 2.5 倍の差があり、原因（Metal/CPU 競合、lattice 非再利用、rich の追加推論など）は未切り分け。今回は狙わず、残課題として POC に回す
- 1〜2 文字読みの cache miss 90% 超は構造的（PLAN260621 と同じ判断）。狙わない

## 5. 実装方針

1. 子音キーで fetch を捨てない: keyDown 前に無条件で世代を進めるのをやめ、handle 後に「AzooKey に渡す読みが変わった／組成が終わった」ときだけ世代を進めてキャンセルする。読みが変わらんキーでは pending タスクと converter の live generation をそのまま残す。Space の rich warm や確定・キャンセル系のキーは従来どおり即キャンセル
2. debounce を詰める: `AzooKeyDebouncePolicy` の通常バケットを 90→60ms、高速打鍵 110→80ms、読み長 ≤2 の下限 120→90ms 程度に下げる（値はテストで固定し、最終値は実装時に決める）
3. sandbox 経路（`DebugSocketServer+AzooKeyAsync`）も同じポリシーを通す
4. テスト: 「か」予約後に子音キーを打っても結果が適用される、読みが変わるキーでは従来どおり破棄される、の 2 本をスケジューラ/ポリシー単位で追加

## 6. 検証ゲート

- サンプル閾値: セッション数 ≥ 100 AND 確定数 ≥ 500
- 計測 window: Step 2 と同じ `7d`（デプロイから 7 日経過後に `--since 7d` で取る。混在を避けるため version でも絞って確認する）
- 比較対象指標: fetch_complete p50 / p95、fetch_complete p95 ≥ 300ms 比率（主）、wasted fetch %・lock_wait p95（副・ガード）

**計測定義の変化に注意**: 以前は子音キーで捨てられとった fetch（debounce + fetch が 1 打鍵間隔を超える遅めのもの）が、変更後は適用されて fetch_complete に数えられる。After の p95 はこの分だけ上に引っ張られるで、p95 が横ばいでも「効いとらん」とは即断せず、wasted fetch % の低下と合わせて読む。p50 は debounce 短縮の効果が素直に出るはずなので主判定に使う。

サンプル不足の場合は `status: in-progress` のまま保留。`status: implemented` を付けるのはゲート通過後のみ。

## 実装メモ（2026-09-29）

- 判定は Core の `WhileTypingFetchRetention.shouldKeepPending`。スケジューラは keyDown を「打鍵記録（handle 前）」と「世代確定（handle 後）」の 2 段に分けた。本番と sandbox の両経路に入れてある
- キャンセル済みの古いタスクが後から新しい予約の pending 状態を消す穴（変更前から存在）を、予約トークンで塞いだ。保持判定がこの状態を見るため必須
- debounce: 通常 90→60ms、高速打鍵 110→80ms、pendingRomaji 105→80ms、読み長 ≤2 の下限 120→90ms
- sandbox E2E: `kanzi` 等の直後に読みを変えんキー（`k` と BS を交互）を 40ms おきに打ち続けても、184〜241ms で候補が届いた（変更前はキーごとに debounce がリセットされ、打鍵が止まるまで届かん挙動）。読みが変わるケース（`kanzi`→`ka`）は `かんじか` の候補だけが出て、古い結果は貼られない。既存 sandbox 回帰（marked text 8/8、candidate cleanup 5/5）も通過

## 残課題（本プランの範囲外）

- fetch 本体の本番 110ms とホスト実測 40ms の差の切り分け（POC 候補）
- left_context が「タグをタグを」のように二重化しとる fetch が 7d で 486/3864 件ある。Zenzai への文脈が壊れとるで精度軸の別サイクルで調べる
