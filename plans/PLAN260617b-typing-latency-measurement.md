---
status: draft
created: 2026-06-17
---

# PLAN260617b: 打鍵体感ボトルネックの実測

## 目的

「体感が遅い」の原因が debounce なのかキャッシュミスなのか Zenzai 推論なのかを、感覚ではなく数値で特定できるようにする。測定結果から次に手を入れる場所を決める。

## 背景

現状の計装はキー打鍵から候補ウィンドウ更新までのパイプラインのうち **C だけ**が計測されている。

```
A: keydown
  ↓ debounce wait（設定値は分かるが実測なし）
B: peekCachedCandidates（exact / prefix / miss — ログなし）
  ↓ キャッシュヒット時はここで終わり
C: requestCandidates 開始〜終了（os_signpost + os_log 済み）
  ↓ Zenzai 推論含む
D: rebuildCandidateList → candidateWindow.apply（ログなし）
```

A→D の end-to-end 遅延がユーザーの体感そのものだが、B と D が計測されていないためどこで詰まっているか分からない。

## 計測したい指標

| 指標 | 意味 | 計測点 |
|------|------|--------|
| cache hit 種別 | exact / prefix / miss の割合 | B: `peekCachedCandidates` の戻り値 |
| AzooKey fetch 時間 | Zenzai 含む辞書変換の所要時間 | C: 既存 os_log を活用 |
| debounce → fetch 完了 | キー後から非同期更新まで | A → D: `AzooKeyAsyncScheduler.onKeyDown` → `rebuildCandidateList` |
| キャッシュ未ヒット率 | 何割のキー押下でフル変換が走るか | B の miss 件数 / 全キー数 |

## 実装方針

### 1. キャッシュ hit ログ（低コスト）

`buildCandidateListWithoutAzooKey` の `peek` 結果を既存の `spLog`（`AzooKey` カテゴリ）に os_log で追記する。1行追加で完結。

```swift
// AzooKeyConverter.peekCachedCandidates または buildCandidateListWithoutAzooKey 内
os_log(.debug, log: spLog, "cachePeek %{public}s → %{public}s", hiragana, peek == nil ? "miss" : peek!.match == .exact ? "exact" : "prefix")
```

### 2. end-to-end signpost（中コスト）

`InputController.runKeyDown` の先頭と `applyCandidateWindowEffects` に `os_signpost` の begin/end を追加する。Instruments の「Points of Interest」で A→D の分布が見られるようになる。

```
os_signpost(.begin, "keydown→candidate", キー識別子)  // runKeyDown 先頭
os_signpost(.end,   "keydown→candidate", キー識別子)  // applyCandidateWindowEffects 内
```

`generation` をキー識別子に使えば非同期コールバック側の end も正しく打てる。

### 3. ローリング統計 + debug socket クエリ（中コスト）

軽量な統計 struct を `AzooKeyAsyncScheduler` または `InputController` に持たせ、debug socket の `stats` コマンドで取得できるようにする。

```
{"command": "stats"}
→ {"cache_exact": 312, "cache_prefix": 45, "cache_miss": 28, "fetch_p50_ms": 42.3, "fetch_p95_ms": 187.1}
```

Instruments を開かなくても `/keynaco-ime-sandbox` の `stats` コマンドで随時確認できる。

## 実装の優先順位

1. **cache hit ログ**（1 日以内）— os_log 1 行追加、Console.app で即確認できる。最小工数でキャッシュ効率の実態が分かる
2. **end-to-end signpost**（1〜2 日）— Instruments で A→D の分布を見たいときに追加
3. **debug socket stats**（2〜3 日）— Instruments を使わず日常的に数値を見たい場合

## この測定から何を決めるか

| 結果 | 次のアクション |
|------|--------------|
| cache miss が多い（> 30%）| LRU 上限 50 件が実使用に足りているか確認。読み長・左文脈キーの設計見直し |
| Zenzai fetch 時間が長い（p95 > 200ms）| Zenzai の `inferenceLimit` 調整、または debounce 上限の見直し |
| debounce wait が支配的 | 可変 debounce の効果を検証。固定値に戻せるか判断 |
| A→D が総じて速い（p95 < 80ms）| 体感問題はレイテンシではなく候補の「質」側にある可能性 |

## 関連

- [PLAN260617-simplify-rank-for-prefix-focus.md](PLAN260617-simplify-rank-for-prefix-focus.md) — 本件の動機となった「効果が測れないまま施策を積む問題」
- `AzooKeyConverter.swift:197` — 既存 `requestCandidates` signpost
- `AzooKeyAsyncScheduler.swift` — `lastInterKeyIntervalMs` 計測の先例
