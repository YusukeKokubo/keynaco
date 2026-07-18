---
status: draft
created: 2026-07-18
objective_axis: latency
baseline_at: 2026-07-18T22:10:19+0900
baseline_window: 7d
sample_threshold:
  sessions: 100
  confirmations: 500
related_plan: PLAN260706-zero-base-hotpath-foundation.md
---

# PLAN260718: 打鍵同期パスの DB/IPC 退避（PLAN260706 Phase 1）

親: [PLAN260706](PLAN260706-zero-base-hotpath-foundation.md) Phase 1 の個別 plan 化。

**位置づけ**: PLAN260710a（D1 助詞トリム）は検証 window（〜2026-07-24）待ちで、grill 決定により E1 の着手は window 消化後。この待ち時間に、指標が直交する latency 軸の構造施策を差し込む。D1 のゲート指標（`とくに` pain / 完成形行の成長）は UX-pain 軸で、本 plan は候補の並び順を変えないため互いの検証を汚さない。

## 1. 目的軸

**latency 削減** — 打鍵同期パス（peek）の p95 テールを削る。毎打鍵の同期処理から DB クエリと AppKit/IMK 問い合わせを退避し、`peek_update p95` を p50 と同じ桁に近づける。

## 2. ベースライン数値（7d、2026-07-18T22:10:19+0900）

保存: `/tmp/perf-cycle-PLAN260718-baseline.txt`（1041 セッション / 4431 確定）

| 指標 | 値 |
|------|-----|
| peek_update p50 | avg 3.0ms（max 12.5ms） |
| **peek_update p95** | **avg 43.8ms（median 43.5ms・max 620.5ms）** |
| fetch p50 / p95 | avg 121.7ms / 197.3ms |
| fetch_complete p50 / p95 | avg 227.9ms / 286.9ms |
| 実効 debounce 待ち（complete − fetch） | median 109.7ms |
| lock_wait p95 | avg 14.4ms（median 0ms・max 404ms） |
| キャッシュ exact / prefix / miss | 12.6% / 36.0% / 51.4% |
| wasted fetch | 37.8%（2845/7534） |
| fetch_complete_p95 ≥ 300ms セッション | 33.4%（348/1041） |
| pain 率（参考・本 plan の対象外） | 10.1%（446/4431） |

比較対象の主要指標（検証ゲート用）:

1. **peek_update p95（avg / median / max）** — 本命
2. fetch_complete p50（inject ビルド軽量化の副次分）
3. 見張り: pain 率・1 位確定率（並び順を変えとらんことの確認。悪化しとったら挙動差が漏れとる）

## 3. 仮説

- **観測**: peek_update は p50 3.0ms に対し p95 が avg 43.8ms・max 620ms と桁違いのテール。A1（peek の同期 lcid 変換排除）後も残存しとる。lock_wait は median 0ms で converter ロックは主犯ではない
- **仮説**: テールの主因は打鍵同期パスに残っとる DB/IPC の同期 hop。PLAN260706 の調査 A（2026-07-18 grep 再確認済み）の通り、(a) prefix focus が候補ごとに最大 2N 本の `dbQueue.sync`（`prefixFocusFilteredSources` → `PrefixFocusPolicy` の `lcidForOutput`/`posForOutput`）、(b) peek と async inject が同じローカルソース収集（DB 3 クエリ）を二度実行、(c) `dbQueue` が read/write 同一シリアルキューのため確定直後の打鍵 read が履歴 record 等の書き込みの後ろで待つ、(d) 毎ビルドの `Calendar.current`+`Date()` 生成、(e) 毎打鍵の `NSWorkspace.frontmostApplication` + `selectedRange()` IPC、(f) dedup 二重。単発は速くても、書き込みと重なった瞬間に数十〜数百 ms のテールとして現れる
- **予測（7d after）**: peek_update p95 avg 43.8ms → **15ms 以下**（狙いは p50 と同桁）、max 620ms → 大幅縮小。fetch_complete p50 227.9ms → 215ms 前後（inject ビルドの DB 3 クエリ削減分の微減）
- **副次効果の予想**: lock_wait は不変（converter に触らんため）。wasted fetch 不変（debounce policy に触らんため）。pain 率・1 位確定率は不変のはず — 動いたら挙動差（ソース鮮度境界）のバグを疑う

## 4. 構造的 vs 可変

| 指標 | 判定 | 理由 |
|------|------|------|
| peek_update p95 テール | **可変** | クエリ本数・hop 回数・IPC 頻度はコードの構造。pos/lcid は打鍵中に不変のデータで、メモ化・引き渡しで排除できる |
| 実効 debounce 待ち 109.7ms | 構造的（本 plan では） | policy の意図した値。再チューニングは単一ロック直列の反証（70ms 化失敗）があり、Phase 2 の coalescing queue 後に解禁 |
| 2 文字読みミス 87.6% | 構造的 | 初出 2 文字は必ず miss。F1 ウォームアップ（別 plan）の管轄 |
| wasted fetch 37.8% | 可変だが本 plan 外 | Phase 2（実行前破棄の構造保証）の管轄 |

## 5. 実装方針

PLAN260706 Phase 1 のチェックリストをそのまま実行する（正本は親 plan、進捗チェックも親側を更新）:

1. `output → (pos, lcid)` のプロセス内メモ化で prefix focus の per-candidate クエリ（最大 2N 本）を撲滅
2. peek ビルドで取得したローカルソース（履歴・辞書）を async inject ビルドへ引き渡し、DB 3 クエリ × 2 回 → × 1 回
3. 残る 3 クエリの 1 hop 統合、または read 専用コネクション分離（WAL 並行 read）。書き込みの後ろで打鍵 read が待つ構造を解消
4. `generateDateTimeCandidates` に早期ガード（`Calendar.current`/`Date()` は日時読みマッチ時のみ）
5. `NSWorkspace.frontmostApplication` 問い合わせを毎打鍵 → activate 時・確定時へ
6. dedup 二重（ScoreBuilder / ScoredLayout）を 1 パスに統合

挙動差が許されるのは「async 到着時のソース鮮度」境界のみ。確定時にメモを invalidate する設計にし、確定 → 即再組成で古い履歴が見えんことを sandbox で確認する（親 plan のリスク表参照）。

## 6. 検証ゲート

- サンプル閾値: セッション数 ≥ 100 AND 確定数 ≥ 500（p95 比較のため既定の 5/100 より厳しめに設定。直近実績 1041 セッション/7d なので 7d 待てば自然に満たす）
- 計測 window: baseline と同じ **7d**
- 比較対象指標: peek_update p95（本命）・fetch_complete p50・見張りの pain 率/1 位確定率
- 成功基準: peek_update p95 avg が明確減（目安 43.8ms → ≤15ms）。pain 率・1 位確定率が悪化しとらんこと
- 機能回帰: `./scripts/test_core_all.sh` + `xcodebuild test` + sandbox 回帰 3 本（marked text / candidate cleanup / prefix focus）+ 確定→即再組成の鮮度境界シナリオ

サンプル不足の場合は `status: in-progress` のまま保留。`status: implemented` はゲート通過後のみ。

## やらないこと

- debounce の再チューニング・投機 prefetch（Phase 2 の土台待ち。単一ロック直列での反証あり）
- `AzooKeyConverter` の actor 化・世代管理の集約（Phase 2）
- スコアリング・dismiss の変更（Phase 3。候補の並び順は一切変えない）
- D1/E1 の学習系施策との混線（D1 は検証 window 消化待ち、E1 はその後。指標が直交しとることが並走の条件）
- F2（長読み Zenzai テール）への直接対策（Phase 2 で解消見込み。残ったら個別 plan）
