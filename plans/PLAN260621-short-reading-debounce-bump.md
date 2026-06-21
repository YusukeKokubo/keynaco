---
status: implemented
created: 2026-06-21
related_commit: e0d0ff9
---

# PLAN260621: 短い読み（≤2 文字）の debounce を max まで伸ばして wasted fetch を削る

## 狙い

`latency_log.jsonl` 24 時間分の集計で **wasted fetch 35.5%（65/183）** が出とった。
`fetch_log.jsonl` を見ると、読み長 2 文字段階で発火した fetch が次キーで結果破棄される
パターンが支配的。`AzooKeyDebouncePolicy` が `interKeyIntervalMs` と `hasPendingRomaji` しか
見とらず、読み長を無視しとったため、2 文字読み（次キーがほぼ確実に来る状況）でも
通常バケット 90ms で発火しとった。

`inter_key_p50 ≈ 112ms` に対して debounce 90ms では、4 割弱の確率で次キーより先に
fetch が走る。短い読みは追加打鍵がほぼ確実なので、ここで待たせれば fetch は構造的に
減る。pause（≥160ms）が来とったらユーザーが手を止めとる証拠なので即発火（45ms）を維持。

## 仮説と前提

- 2 文字読みのキャッシュミス率 90% は構造的（各単語の初出 2 文字は新規）で debounce では
  解決せん。狙いは「ミスらせるけど発火させない」＝ wasted fetch の削減
- Zenzai 推論を 1 本 ~88ms 走らせとるので、wasted fetch を半減できれば
  `LockedConverter` の queue 詰まり（`lock_wait`）にも副次的に効く
- 読み長 3 文字以上は既存ポリシー維持（90ms）— 短いほうだけ局所修正

## 実装

`AzooKeyDebounceInput` に `readingLength: Int` を追加。
`readingLength ≤ 2 && interKeyIntervalMs < 160`（または `nil`）のとき `ms = max(ms, 120)`。

呼び出し側 2 箇所（`InputController+AzooKeyAsync` / `DebugSocketServer+AzooKeyAsync`）
で `reading.count` を渡す。テスト 4 件追加（短読み打鍵中・短読み高速打鍵中・短読み pause・
長読み非影響）。

## 結果

デプロイ後 15 分・3 セッション・36 確定の実測:

| 指標 | Before (24h) | After (15m) |
|---|---|---|
| **wasted fetch** | **35.5%** | **19.4%** |
| fetch_complete p50 | 195ms | 207ms |
| fetch_complete p95 | 266ms | 257ms |
| inter_key p50 | 119ms | 114ms |
| lock_wait p95 | 58ms | 9.5ms |

wasted fetch が 16pt 改善（相対 -45%）。lock_wait p95 も 58 → 9.5ms に落ちて、副次効果が
出とる。fetch_complete は p50/p95 ともほぼ変わらず、debounce 引き伸ばしによる体感遅延は
観測されなかった。

サンプル数が少ない（n=3）ので fetch_complete_p95 の安定性は要追跡。1〜2 日分溜まったら
再評価する。

## 残課題（このプランの範囲外）

実測で見えた残り pain ケースは **2 文字読みの同音異義語の Zenzai 精度問題**：

- `'はし' → '椅'`（scroll 12 回）
- `'かな' → '仮名'`（scroll 7 回）

Z1 がひらがなのまま留まり、ユーザーが下位候補を掘っとる典型パターン。debounce では
解けず、別軸の施策が必要：

- 短い読みでの履歴スコア重み増（過去確定の '橋' '箸' '椅' を Z1 より優先）
- 短い読みのカタカナ偏向の補正

これは別 plan として切り出す。
