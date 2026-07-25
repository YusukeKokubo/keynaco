---
status: in-progress
created: 2026-07-19
objective_axis: CPU-waste
baseline_at: 2026-07-19T19:45:00+0900
baseline_window: 7d
sample_threshold:
  sessions: 100
  confirmations: 500
related_plan: PLAN260706-zero-base-hotpath-foundation.md
parent_roadmap: PLAN260719-headroom-roadmap.md
---

# PLAN260719a: 変換パイプライン Phase 2（H1）

親: [PLAN260706](PLAN260706-zero-base-hotpath-foundation.md) Phase 2 / [PLAN260719](PLAN260719-headroom-roadmap.md) H1。

**位置づけ**: PLAN260718（Phase 1）の検証 window（〜07-25）と並走。UX-pain 指標（D1/E1）と直交する CPU-waste / 構造返済軸。

## 1. 目的軸

**CPU 無駄削減** — `wasted fetch` と世代管理の複雑さ返済。副次効果として debounce 短縮（H2）・投機 prefetch の解禁土台。

## 2. ベースライン数値（7d、2026-07-19T19:45:00+0900）

保存: `/tmp/perf-cycle-PLAN260719a-baseline.txt`（1055 セッション / 1041 fetch_complete）

| 指標 | 値 |
|------|-----|
| fetch p50 / p95 | avg 121.5ms / 204.7ms |
| fetch_complete p50 / p95 | avg 227.4ms / 286.6ms |
| lock_wait p50 / p95 | avg 0.5ms / 14.3ms（median 0ms） |
| wasted fetch | **37.7%**（2876/7632） |
| キャッシュ miss | 51.4% |
| peek_update p95 | avg 43.8ms（Phase 1 検証待ち・本 plan の主ゲートではない） |

## 3. 仮説

| 項目 | 判定 | 根拠 |
|------|------|------|
| `LockedGeneration` + `abortBeforeFetch` + `Task.detached` の 3 点セット | 構造的負債 | 世代判定が scheduler / converter / arrival の 3 箇所に分散。空配列 = abort の暗黙契約で wasted 計測が脆い |
| キャッシュのロック外 read | 構造的 | MainActor peek × background write の潜在 race |
| 学習 commit 後のキャッシュ非無効化 | 可変 | 確定後も古い候補列が残り得る |
| debounce 短縮 | Phase 2 後（H2） | coalescing の構造保証が先 |

## 4. 実装スコープ（PLAN260706 Phase 2 チェックリスト）

- [x] 世代管理を converter 側に集約（`setLiveGeneration`）。scheduler の `LockedGeneration`・`abortBeforeFetch`・`Task.detached` を廃止
- [x] `FetchRequestOutcome` で aborted / wasted / success を明示
- [x] キャッシュ read/write を `cacheLock` で直列化（peek は inference を待たない）
- [x] 確定学習後に該当読みのキャッシュエントリを purge
- [x] `lcidForCommitted` をキャッシュヒット優先に（ミス時のみ engine 問い合わせ）
- [ ] `LockedConverter` NSLock → 単一直列 executor への統合（残タスク）

**Phase 2 では触らない**: debounce 数値変更（H2）、増分 lattice（H6）、スコアリング単純化（Phase 3）。

### 同梱した H2 前提検証スイッチ（デフォルト無効）

`AzooKeyDebouncePolicy.overrideMs`（`defaults write com.yusuke.inputmethod.keynaco debugDebounceOverrideMs -int 70` → 再起動）を追加した。**未設定なら通常ポリシーのままなので Phase 2 の指標には影響せん**。

狙いは残タスク（`LockedConverter` → 直列 executor）の投資判断の前提を 1 定数で確かめること。最新ビルド（845）の実測は `lock_wait p95 = 0ms / max 55ms` で、**ロック待ちがそもそも起きとらん**。この状態が「debounce 90–120ms で発火を絞った結果」なのか「直列化がもう壁になっとらん」のかで残タスクの価値が変わる。override で 70ms に詰めて lock_wait が復活するなら前者＝残タスクに意味あり、復活せんなら後者＝残タスクは保守性目的に格下げし、無駄先読みの主因（推論時間そのもの、H6）へ寄せる。

**実験順序**: Phase 2 前半の 7d 計測を先に取り切る → その後 override を立てて別セッション群として測る（同時に動かすと wasted fetch がどちらの効果か分からんくなる）。

## 5. 検証ゲート

| # | 条件 |
|---|------|
| 1 | `./scripts/test_core_all.sh` 緑 |
| 2 | `xcodebuild test -scheme keynaco` 緑 |
| 3 | sandbox 回帰 3 本 緑 |
| 4 | `/deploy` 後 実機 smoke |
| 5 | 7d 再計測: wasted fetch が baseline 37.7% から低下、lock_wait p95 悪化なし |

`sample_threshold`（sessions ≥100）満たすまで `status: implemented` にしない。

## 6. ロールバック

挙動差・race 疑い時は本 plan のコミット単位で revert。Phase 1（PLAN260718）の peek 改善は独立。
