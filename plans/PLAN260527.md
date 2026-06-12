---
status: abandoned
created: 2026-05-27
related_rejected: J-1
---

# PLAN260527 — Apple Intelligence を使った日記（日報）自動生成

## 概要

keynaco で入力した日本語テキストを素材に、Apple Intelligence（FoundationModels）が1日分の日記・日報を自動生成する機能。

## 基本方針

- **データ収集**: IME Extension が変換確定したテキストを共有 SQLite に積む
- **生成**: Settings アプリ側で `FoundationModels.respond(to:)` を呼んで要約・日記化
- **保存先**: 端末内（ユーザーのプライベート空間）のみ。自動公開なし

## アーキテクチャ

```
IME Extension（サンドボックス）          Settings / 本体アプリ
─────────────────────────────          ─────────────────────────────
変換確定テキストを                  →    1日分のエントリを読む
App Groups 共有 SQLite に蓄積              ↓
（既存の学習 DB に相乗り検討）          FoundationModels.respond(to:)
                                         で要約・日記生成
                                              ↓
                                         Settings UI に表示
                                         or テキストファイルとして保存
```

## 実装ステップ

### Step 1: 入力ログ収集

- 変換確定時（`commitText` 相当のタイミング）に確定テキストを App Groups 共有 SQLite へ INSERT
- スキーマ案:
  ```sql
  CREATE TABLE daily_log (
      id INTEGER PRIMARY KEY,
      date TEXT NOT NULL,       -- "2026-05-27"
      committed_text TEXT NOT NULL,
      created_at INTEGER NOT NULL  -- unixtime
  );
  ```
- 既存の学習 DB（`KeynacoCore` の SQLite）に相乗りできるか検討する

### Step 2: Settings UI

- 「日記を生成」ボタンを Settings に追加（新規タブ or 既存タブに追加）
- 日付ピッカーで対象日を選択（デフォルト: 今日）
- 生成済み日記の一覧表示

### Step 3: Apple Intelligence 呼び出し

```swift
// Settings アプリ側（IME サンドボックス外）で実行
let session = LanguageModelSession()
let log = fetchDailyLog(for: date)  // Step 1 で蓄積したテキスト
let prompt = """
以下は \(date) に入力した日本語テキストの一覧です。
これを素材にして、その日の出来事・作業内容を自然な日本語の日記としてまとめてください。

\(log.joined(separator: "\n"))
"""
let response = try await session.respond(to: prompt)
```

- `respond(to:)` プレーンテキスト方式を使う（IME サンドボックス外なので Guided Generation も試す価値あり）
- 出力フォーマットは厳密に指定せず「自由文の要約」として受け取る（フォーマット追従性の低さを回避）

### Step 4: 保存・エクスポート

- 生成テキストを SQLite or ファイルに保存
- コピーボタン・共有ボタンで他アプリへエクスポート

## 確認が必要な点

- [x] Settings アプリ側での Guided Generation の動作 → **✅ 動作確認済み（2026-05-27）**。`respond(to: prompt, generating: T.self)` で `@Generable` 構造体が正常に返った。日記生成に構造化出力が使える。
- [ ] 既存学習 DB に相乗りするか、専用テーブルを追加するか
- [ ] 収集対象: 変換確定テキストのみか、英字入力も含めるか
- [ ] 1日の入力量が多い場合のトークン上限対策（要約を分割処理など）

## 関連ドキュメント

- `docs/apple-intelligence.md` — FoundationModels の制約・実験結果
- `plans/PLAN260525c.md` — Guided Generation サンドボックス制約の詳細調査
