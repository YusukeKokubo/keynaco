---
status: draft
created: 2026-07-19
---

# PLAN260719: 残り伸び代の棚卸しロードマップ

打鍵体感改善の**残り伸び代を 1 枚に集約した index / 意思決定文書**。実行はこれまでどおり `/keynaco-perf-cycle` の個別 plan で行い、本 plan は「何が残っとるか」「どの順で切るか」「どこで頭打ちと判定して抜本枠を開くか」だけを持つ。個別施策の設計詳細は所属 plan が正本。

## 位置づけ（既存 plan との関係）

- **PLAN260704b（第 1 弾・点対策）**: A1–A4・B1–B2 完了。B1/B2 は対策不足が確定しており、その再対策は本 plan の台帳（H7）に引き継ぐ。進捗表が全行終端になった時点で implemented に閉じてよい
- **PLAN260710（第 2 弾・学習系）**: E1 / D2 / F1 / F2 の正本。優先順・判定は本 plan と同期する
- **PLAN260706（構造リファクタリング）**: Phase 2–4 の正本。Phase 1 は PLAN260718 として実行済み（検証 window 待ち）
- 本 plan が終端になる頃には、上記 3 つの親 plan も全行終端になっとるはず

## 現状スナップショット（2026-07-18、7d・1041 セッション / 4431 確定）

| 軸 | 到達点 | 残っとる床 |
|----|--------|-----------|
| UX-pain | pain 率 16.3% → **10.1%**、1 位確定率 82.5% → **90.0%** | prefix 習慣（とりひ型 66+ pain/14d）、数字・日付クラスタ |
| latency | lock_wait 沈静化（median 0ms）、Space 即時化（p95 0.1ms）、peek p50 3.0ms | **fetch_complete p50 228ms ≈ debounce 待ち 110ms（keynaco 側）+ fetch 122ms（ほぼ Zenzai 推論）**。wasted fetch 37.8%、キャッシュ miss 51.4% |

要点: 体感レイテンシの約半分（debounce 待ち）は**エンジンと無関係の keynaco 側ポリシー**で、構造制約（単一ロック直列 converter）のせいで未着手。pain 側の最大単一レバー（E1）も未着手。「エンジン以外はやりきった」状態には程遠い。

## 伸び代の台帳

| ID | 施策 | 層 | 期待効果（根拠） | 正本 plan | 状態 |
|----|------|-----|-----------------|-----------|------|
| H1 | Phase 2: converter actor 化 + 世代管理集約 + 学習後キャッシュ無効化 | 非同期パイプライン | debounce 短縮・投機 prefetch の**解禁**。wasted fetch 37.8% の実行前破棄 | PLAN260706 Phase 2 | 未着手（着手可） |
| H2 | debounce 再チューニング | 同上（H1 後） | 待ち median 110ms → 50〜60ms 級。fetch_complete p50 の最大単一成分 | PLAN260706 Phase 4 枠 → 個別 plan | H1 待ち |
| H3 | E1 prefix 習慣学習（whileTyping 限定） | 履歴 DB + スコア | とりひ/れびゅ/してき型 66+ pain/14d。**pain 側の最大単一レバー** | PLAN260710 E1 | D1 window（〜07-24）待ち |
| H4 | F1 起動キャッシュウォームアップ | キャッシュ | 2 文字 miss 4613 件/7d のセッション頭分 | PLAN260710 F1 | H1 後（キャッシュ構造の安定後） |
| H5 | D2 文節完成形の row 0 到達 | 履歴 DB | 「いまは」型。D1 の自然増で縮小の公算 | PLAN260710 D2 | D1 の 14d 観察で要否判断 |
| H6 | 増分 lattice（`kana2lattice_no_change`）活用 POC | エンジン API の使い方 | fetch p50 122ms の下げ余地（1 文字追加時の全再構築をやめる） | PLAN260706 Phase 4 | H1 後 POC |
| H7 | 数字・日付 pain の再対策 | スコアリング | B1/B2 で「スコアは上がったが到達時間が縮まん」と確定済みの再挑戦。pain 最大クラスタの残り | 新個別 plan（要 baseline） | 未着手・独立 |
| H8 | Phase 3: スコアリング・dismiss 単純化 | 候補構築 | 速度より保守性。promote/demote 3 層の畳み込み。H7 の前提整備 | PLAN260706 Phase 3 | E1 検証後（指標窓を汚さんため） |
| H9 | エンジン追従調査（AzooKey 最新版・zenz-v3.2 右文脈） | エンジン境界 | concept「追従は義務・遅れは純粋な弱み」。上流改善の取り損ね解消。効果未知だで**まず調査 plan** | 新規 | 未着手・いつでも並走可 |
| H10 | 段階表示 POC（打鍵中 Zenzai 停止 → pause/explicit で推論） | 製品挙動 | fetch のほぼ全部が Zenzai 推論。divergence 救済率 72% が「打鍵中 Z1 品質の代償は小さい」ことを示唆 | 新規（**判定ゲート G2 で開く条件付き引き出し**） | 封印中 |
| H11 | 小粒テール: peek prefix 線形走査（親調査 A-7）・毎打鍵 `selectedRange()` IPC | 同期パス | PLAN260718 検証後に peek p95 が残った場合の次候補 | 新個別 plan | G1 の結果待ち |

## 優先順と依存関係

```
現在（D1/PLAN260718 の window 消化中）
  ├─ H1 Phase 2 着手可（学習系指標と直交、並走 OK）
  └─ H9 エンジン追従調査 並走可（コード変更なしの棚卸しから）
07-24 D1 ゲート → H3 E1 着手（baseline は D1 適用後で取り直し）
07-25 PLAN260718 検証 → G1 判定 → 必要なら H11
H1 完了 → H2 debounce 個別 plan → G2 判定 → 必要なら H10 開封
H1 完了 → H4 F1 / H6 増分 lattice POC
H3 検証後 → G3 判定 → H8 Phase 3、H7 は独立にいつでも（baseline から）
D1 の 14d 観察 → H5 D2 の要否確定
```

## 判定ゲート（頭打ちの宣言条件。ずるずる続けんため）

| ゲート | タイミング | 判定 | No のとき |
|--------|-----------|------|----------|
| G1 | 2026-07-25（PLAN260718 検証） | peek_update p95 avg 43.8ms → ≤15ms か | テール仮説を見直し、H11（A-7 / IPC）を個別 plan 化 |
| G2 | H2（debounce 再チューニング）検証後 | fetch_complete p50 < **180ms** か | 床は Zenzai 推論と確定 → H10（段階表示 POC）を開く |
| G3 | H3（E1）検証後 | pain 率 < **8%** か | 残 pain は学習系以外と判断 → クラスタ再分析（H7 優先度引き上げ） |

## 構造的で追わないもの（再確認）

- 2 文字読み miss 率そのもの（初出は必ず miss。F1 はセッション頭の緩和のみ）
- llama 推論の中断機構の自作（upstream 領域）
- debounce 待ちの完全ゼロ化（coalescing の意味がなくなる。狙いは短縮）

## 滞留 plan の triage（本棚卸しで確定した処置）

| plan | 実態 | 処置 |
|------|------|------|
| PLAN260612（非同期二段階化） | Phase 3.5 まで ✅、主目的達成 | **implemented に更新**。複雑さ返済は PLAN260706 Phase 2 が後継、と一行追記 |
| PLAN260617c（レイテンシログ永続化） | `latency_log.jsonl` として稼働中 = 本 plan 群の計測基盤そのもの | **implemented に更新** |
| PLAN260528（履歴セグメントノイズ） | D1（lcid 判定トリム）+ D2 検討に実質吸収 | **superseded に更新**（後継: PLAN260710） |
| PLAN260621b（recency 重み強化） | E1 と同じ pain を別レバー（recency）で狙う draft | E1 着手時に**統合 or abandon を判断**（二重レバーは効果測定を壊す） |
| POC260529（personalization n-gram） | 機構有効・データ律速で保持 | 観察継続。`docs/observation.md` への移管を検討 |
| PLAN260523d（IME 簡素化） | Step 4（bracketOptions 間引き）のみ未着手 | Step 4 の要否を判断して**閉じる**（1 セッション仕事） |
| PLAN260611（コードベースリファクタ） | 残タスクは Phase 6（plans/docs 棚卸し）のみ | 本 plan の triage が実質の後継 → **implemented に更新** |

## 完了条件

- 台帳 H1–H11 の各行が「個別 plan として着手済み」または「終端判断済み（見送り理由付き）」になる
- 判定ゲート G1–G3 がすべて判定済みになる
- triage 表の処置がすべて実施される（status 更新 or 判断記録）

このとき本 plan を implemented にし、次のロードマップは改めて計測から起こす。
