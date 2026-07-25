# in-process 計測ログの一覧

Instruments によるプロファイリングは IME では実用的でない（UI にフォーカスが奪われ自然な打鍵ができない）。in-process 記録が唯一の実用手段で、Claude Code からそのまま読んで分析できる。

いずれも `~/Library/Application Support/keynaco/` 配下。

| ログ | 内容 |
|------|------|
| `latency_log.jsonl` | 変換レイテンシ・キャッシュヒット率（セッション単位）。このスキルの主な分析対象 |
| `input_log.jsonl` | 確定ごとの入力品質（`key_count`・`bs_count`・`composition_ms`・`was_explicit`）。バッファ 10 件 or `deactivateServer` でフラッシュ |
| `divergence_log.jsonl` | Zenzai が推した Z1 と実確定が食い違ったケースだけ 1 行記録。`was_explicit=false` なら自動表示中の素通り事故、`true` なら Z1 精度の改善余地（カタカナ偏向など）。バッファ 10 件 or `deactivateServer` でフラッシュ |

バッファのフラッシュ条件があるため、直近の打鍵が反映されとらんことがある。サンプル数が足りんときは `deactivateServer` を経由させる（入力ソースを切り替える）か、しばらく打ってから読み直す。
