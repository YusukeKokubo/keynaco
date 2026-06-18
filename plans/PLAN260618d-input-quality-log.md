---
status: implemented
created: 2026-06-18
---

# PLAN260618d: 入力品質ログ（input_log.jsonl）

## 目的

打鍵体感・変換精度・品質を後から定量的に調べられるようにする。
「さっき変な確定した」「なんか最近重い？」をログから追えるようにする。
ユーザーが問題に気づかなくても、異常なパターンをログ上で検出できるようにする。

## ログの単位

**1エントリ = 1変換セッション**（組成開始 → 確定 or キャンセルまでの一連の打鍵）。

latency_log.jsonl と同じ JSONL 形式。パスは
`~/Library/Application Support/keynaco/input_log.jsonl`。

## フィールド定義

### メタ

| フィールド | 型 | 説明 |
|-----------|-----|------|
| `version` | String | ビルドバージョン（latency_log と同フォーマット） |
| `ts` | Int | セッション終了時刻（Unix ms） |

### 打鍵体感

| フィールド | 型 | 説明 |
|-----------|-----|------|
| `key_count` | Int | 組成中の総打鍵数（BS・スクロールも含む） |
| `bs_count` | Int | Backspace 回数 |
| `composition_ms` | Int | 組成開始〜確定/キャンセルまでの時間 |

### 変換精度

| フィールド | 型 | 説明 |
|-----------|-----|------|
| `reading` | String | 最終的な composedHiragana（確定/キャンセル時点） |
| `committed` | String? | 確定テキスト。キャンセル（Escape）なら null |
| `candidate_depth` | Int? | 確定時の selectedRow（Space も押さず Enter なら 0） |
| `was_explicit` | Bool | Space 等で .explicit に入ってから確定したか |
| `scroll_count` | Int | ↓↑ の合計回数 |

### 品質・異常検出（anomaly）

`anomaly` フィールドは種別の文字列配列。複数同時に立つ場合あり。

| 種別 | 条件 |
|------|------|
| `penalized` | 確定直後に BS → penalizeAll が走った（誤変換の訂正） |
| `escaped_long` | reading.count >= 3 の組成を Escape でキャンセル |
| `deep_scroll` | scroll_count >= 4（4件以上スクロールして確定） |
| `re_typed` | 直前確定の reading と今回の reading が一致（確定し直し） |

### 設計上の判断

- 打鍵中のローマ字（pendingRomaji）は記録しない。読みと確定結果があれば再現できる
- `reading` は読み（ひらがな）のみ。確定候補と比較すれば変換精度がわかる
- `candidate_depth` が深い読みを集計すると「この読みは候補精度が悪い」が見える
- `re_typed` は次のセッションで前回結果と比較して付与する
- `consonant_bs` （今回修正したバグのパターン）は anomaly ではなく正常操作なので記録しない

## 実装方針

### データ収集箇所

`InputHandler` に `InputSessionTracker` struct を追加（純粋 struct、副作用なし）。
各打鍵で `track(key:result:)` を呼んでセッション内状態を更新。
セッション終了（`commitComposition` / `doEscape`）で `InputSessionRecord` を返す。

`InputController`（アプリ層）が record を受け取って `InputQualityLogger` に渡して書き込む。

### ファイル管理

起動時トリミング: 過去 30 日分 or 最新 20000 セッション（先に超えた方）。
latency_log の `trimLatencyLog` と同じパターンで実装する。

### 分析

`scripts/analyze_input.py` を新規作成。`latency_log.jsonl` の `analyze.py` を参考に。
anomaly 集計・reading 別 candidate_depth 分布・bs_count/key_count 比などを出力する。
Claude Code から直接読んで「最近の傾向」を分析できるようにする。

## 今後の拡張候補（現バージョンでは含まない）

- `inter_key_p50_ms`: キー間隔中央値（打鍵速度）。latency_log 側で既に集計しているので重複しないよう検討
- アプリ別セッション（どのアプリで入力したか）: IMK の `client.bundleIdentifier` で取れるが個人情報に近い
