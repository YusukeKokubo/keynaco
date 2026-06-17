# Zenzai 遅延調査レポート

調査日: 2026-06-17  
ログ: `~/Library/Application Support/keynaco/latency_log.jsonl`  
セッション数: 102（当日分のみ、全ログ）

---

## 結論

**「Zenzai が遅い」をこのログから証明することはできない。** 全102セッションで `fetch_p95_zenzai_off` フィールドが存在しない。つまり Zenzai OFF の変換が1件も記録されていないため、ON/OFF の比較対象がない。ログは「Zenzai ON 環境でこの速度だった」という事実しか教えてくれない。

体感的に遅いと感じているなら根拠はある。ただし遅さの原因が Zenzai 固有なのか、AzooKey 変換全体の問題なのかはこのログでは判断できない。

---

## 計測値

| 指標 | 中央値 | 最大値 | 備考 |
|------|--------|--------|------|
| fetch_p50 | 96 ms | 376 ms | セッション内p50の中央値 |
| fetch_p95 | 151 ms | 376 ms | セッション内p95の中央値 |
| complete_p50 | 195 ms | 462 ms | 候補確定まで含む |
| complete_p95 | 237 ms | 525 ms | 候補確定まで含む |
| peek_update_p50 | 2 ms | — | peek差分更新（軽い） |

`fetch_p95 > 200ms` のセッションが全体の30%（30/101件）あり、`> 300ms` が5%（5/101件）。p95 ベースで見ると体感できるレベルの遅延が頻繁に発生している。

---

## ログから読み取れること

**fetch = 純変換時間（debounce を含まない）**  
`recordFetch` は `AzooKeyConverter.requestCandidates()` 内の計測で、呼び出された瞬間から結果が返るまでの時間。debounce 待ちはその前に終わっている。つまり fetch_p95=151ms という数字は「キーを打ってから候補が揃うまで」ではなく、「変換処理そのものに151ms かかった」という意味。

**debounce は fetch に乗らない**  
`debounce_policy_p50_ms` は70ms が最多（72セッション）。これは変換リクエストが発火する前の待ち時間で、`fetch_complete_p95`（中央値237ms）との差分（約90ms）がおおむね候補ウィンドウの表示コストや debounce の累積分にあたる。

**peek_update は速い**  
キャッシュヒット時の差分更新（peek_update_p50）は中央値2ms で問題なし。遅延は専らキャッシュミス時の変換処理に集中している。

**キャッシュミス率と遅延の相関は弱い**  
ミス率と fetch_p95 の相関係数は -0.04。「キャッシュミスが多いセッションほど遅い」という傾向はなく、変換1件あたりの所要時間そのものがばらついている。

---

## ログから読み取れないこと

**Zenzai の寄与を分離できない**  
`fetch_p95_zenzai_on` は全セッションで `fetch_p95_ms` と完全に一致する（差分ゼロ）。これは Zenzai OFF で変換した記録がゼロだったことを意味する。Zenzai を無効化したセッションを意図的に作らない限り、「Zenzai が何ms 追加しているか」は計算できない。

**モデル推論時間 vs AzooKey コア変換時間**  
現状のログは `requestCandidates()` 全体を1つのタイマーで計測している。Zenzai の llama 推論部分だけを取り出したタイマーはない。遅さが LLM 推論に起因するのか、AzooKey の辞書引き・候補ソートに起因するのかはわからない。

**候補確定データがほぼない**  
`candidate_confirmations` の合計が1件しかない（ほぼ全セッションが flush 条件の5回未満で強制 flush されている）。`first_candidate_rate=1.0` / `selection_depth_p50=0` はデータ不足で信頼できない。

---

## 調査を進めるなら

1. **Zenzai ON/OFF を交互に使うセッションを作る**。設定で Zenzai を切って同じ文章を打ち、ログをフラッシュして `fetch_p95_zenzai_off` と `fetch_p95_zenzai_on` を直接比較する。

2. **Zenzai 推論単独のタイマーを追加する**。`AzooKeyConverter.requestCandidates()` の内部で、llama 呼び出し前後を別タイマーで計測して `zenzai_infer_p95_ms` をログに足す。これで「全変換時間 vs LLM 推論時間」が分離できる。

3. **`/keynaco-ime-sandbox` スキルで特定入力を繰り返し送る**。ソケットデバッグサーバーで同じ読みを10回送って `wait_azoo_key` の応答時間のばらつきを見ると、ウォームアップ後の定常遅延が把握できる。
