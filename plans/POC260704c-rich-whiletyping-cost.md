---
status: abandoned
created: 2026-07-04
related_plan: PLAN260704b
---

# POC260704c: whileTyping rich=true コスト実測

PLAN260704b C1。whileTyping 非同期 fetch の `richCandidates: true` を `false` に切り替える価値があるかを計測。

## 仮説

Space warm 用の rich 先読みが 92% の打鍵で無駄コストを払っている。

## 計測

`keynacoTests/AzooKeyRichCostHostedTests`（アプリバンドル + Zenzai 実機、inferenceLimit=2）。

## 結果

| | p50 | p95 | mean |
|--|-----|-----|------|
| rich=false | 42.3ms | 133.8ms | 50.0ms |
| rich=true | 37.6ms | 101.7ms | 43.7ms |

p50 差分 **-11.0%**（rich 優位）。判断基準 20% 未満。

## 判断

**現状維持**。rich=false への切り替えは採用しない。Space 時の rich キャッシュヒット設計を維持。
