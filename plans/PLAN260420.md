# タイプ数削減のための予測入力強化（アイデア集）

## 背景と目的

IME としての価値は「少ない打鍵で意図したテキストに辿り着けること」。
現状の打鍵削減機能：

- 履歴 prefix マッチ（短い読みで長い既出語を候補に出す）
- bi-gram 候補（直前確定語 × 現在の読みで絞り込み）
- 格助詞モード（漢字・カタカナ末尾のとき 0 打鍵で格助詞候補を提示）

ここから「もう一段」削るための案をまとめる。本ドキュメントは **着手確定ではなく引き出し** として残す。
各案は独立に実装可能。優先度は主観のもので、実装前にベンチ（打鍵削減量の実測）を取ってから確定させる。

---

## 案 1: 確定直後の bi-gram プレ候補（格助詞モードの一般化） ★最優先候補

> **実装済み（2026-04-20）**: 詳細設計・変更箇所は `~/.claude/plans/1-bi-gram-dynamic-clover.md` を参照。
> 格助詞モードを Successor モードに一般化し、任意の確定語の直後に `fetchBigramTop` 上位候補を 0 打鍵で表示。
> 格助詞固定リストは `isNounLike` のときのみ tail に fallback として残す。

### 現状

`doSuggestParticles()`（`InputHandler.swift:334`）は以下の制限付き：

- 発火条件: `lastCommittedOutput` が **漢字・カタカナ末尾の「名詞らしい語」** のとき（`isNounLike()` で判定）
- 候補: **格助詞固定リスト**（`InputHandler.particles`）を bi-gram スコアで並び替え
- 1 打目バッファリング → 2 打目が格助詞候補にマッチしなければ通常入力に流す

### 改善

**全ての確定後**、`lastCommittedOutput` を prev として `bigram.fetchBigramByPrev(prev:)` のトップ N 件を
候補ウィンドウに自動表示する。格助詞 **以外の頻出後続語**（「で」「に」だけでなく「行く」「さん」「株式会社」など）
も 0 打鍵で候補に並ぶ。

### 設計スケッチ

- `DatabaseManager` に `fetchBigramByPrev(prev: String, limit: Int) -> [String]` を追加
  （既存の `fetchBigram(prev: reading:)` は reading LIKE 検索が必要なため、prev だけで引くクエリを新設）
- `doSuggestParticles()` を `doSuggestSuccessors()` に一般化：
  - 発火条件の `isNounLike()` を撤廃（ひらがな確定でも bi-gram があれば表示）
  - 候補リストを「bi-gram top N + 格助詞フォールバック」に変更
  - 既存の `isParticleMode` / `particleFirstChar` バッファリングは流用可
- 1 打目が bi-gram トップ候補の頭文字と一致しないとき通常入力に流す挙動を、`particleRomajiMap` ベースから
  「予測候補の先頭文字集合」ベースに差し替える

### リスク

- 候補が多く出過ぎてノイズになる（`bigram.count >= N` 等で閾値を設けて出現頻度が低いものは出さない）
- 1 打目バッファリングの範囲が広がることで「通常入力が 1 打遅延する」ユーザー体感の悪化
  → トップ候補の先頭文字集合でフィルタし、マッチしない打鍵は即通常入力に流す（現実装と同じ）

### 効果の想定

現在 `bigram` テーブルに `INSERT ... ON CONFLICT DO UPDATE` で積まれているデータがそのまま使える。
「東京」「会議」「お疲れ様」など高頻度語の直後の打鍵は多くが 1 文字以内で済むようになる。

---

## 案 2: インライン予測（ghost text）+ Tab 確定

### 現状

- 組成中の最上位候補を採るには `↓` → `Enter`（2 打）
- `→` はひらがな確定、`Enter` は組成確定。Tab は候補ウィンドウ表示中のみ `.selectNext` に使われている

### 改善

組成中に最上位の履歴/bi-gram 候補を **markedText の後ろにゴースト（薄色）** として表示し、**Tab で一発確定**。

```
入力: "to" → markedText: "と" + ghost: "うきょう" (薄色) → Tab で "東京" 確定
```

### 設計スケッチ

- `setMarkedText` に `NSAttributedString` を渡し、
  - 現組成（`composedHiragana + pendingRomaji`）は通常色 + 下線
  - ゴースト部分は半透明グレー（カーソル位置はゴーストの前に置く）
- `InputHandler.handle` の Tab 処理：
  - 候補ウィンドウ表示中 & トップ候補ありなら、それを `insertText` で確定
  - 候補ウィンドウ非表示 & 履歴 prefix / bi-gram トップがあればそれを挿入
- 既存の Tab の `.selectNext` 挙動との兼ね合い：
  - 格助詞モード中は現状通り `.selectNext`
  - 通常の候補選択中も `.selectNext` のまま
  - Tab = 「ゴースト採用」は **ゴースト表示中のみ** に限定

### リスク

- IMK クライアント側で `NSAttributedString` の属性を受け取らないアプリがある（Electron 系要検証）
  → フォールバックとして「下線なしの plain text を後ろに連結する」か、ゴーストを表示せず
  候補ウィンドウだけに頼るオプション設定を用意
- Tab 競合: `insertText("\t")` を期待するアプリで意図しない確定が起きる
  → 「ゴースト表示中のみ」で発火することで大半は回避できる

### 効果の想定

履歴が育っているワーク中（同じ単語を繰り返し使う状況）で打鍵が体感 2–3 割削れる見込み。
案 1 との組み合わせで、確定 → 0 打鍵ゴースト → Tab、というフローが作れる。

---

## 案 3: n-gram 拡張（bigram → trigram）

### 現状

`bigram` テーブルは `(prev, input, output)` で **1 語前** のみ文脈化。

### 改善

`trigram` テーブル `(prev2, prev1, input, output, count, used_at)` を追加し、
2 語前まで遡って予測精度を上げる。trigram ヒットが 0 件なら bigram にフォールバック。

例: 「昨日 / 東京 / に」→ `行った` が trigram トップ、bigram だけでは「行く」や「住む」が混じる。

### 設計スケッチ

- `DatabaseManager` にテーブル追加 + `fetchTrigram(prev2:prev1:reading:)` / `recordTrigram(...)` を実装
- `InputHandler` に `lastCommittedOutputs: [String]`（直近 2 件、スライディングウィンドウ）を保持
  （現在の `lastCommittedOutput: String?` を置き換え）
- `doRefreshCandidates()` の bi-gram 参照箇所で trigram → bigram の順に問い合わせる
- 確定時に両方のテーブルに書き込む（`record(input:output:)` と並行して）

### リスク

- データ量: 2 語前まで含めると組み合わせ爆発。使用頻度の低いエントリを定期掃除する LRU 的なクリーンアップが必要
- 学習が効くまで時間がかかる（bigram より発火条件が厳しいため、ヒット率は低めから始まる）

### 効果の想定

案 1 の効果を増幅する方向。単体での効果は地味だが、十分使い込んだ後は大きい。

---

## 案 4: 英字・略語の学習と短縮記法

### 現状

日本語モード中の Shift+ASCII 文字は `composedHiragana` に直接追加され、Enter で確定する（例: `API`, `PR`, `URL`）。
確定したものは `history` に `input: "API", output: "API"` として入るはず（要確認）。

### 改善

- 英字読み → 英字出力の **大文字化学習**: `api` と打って `API` を選んだ履歴を学習し、以降 `api` の prefix マッチで `API` を上位に出す
- 略語辞書の自動生成: 頻出英単語の短縮入力（`gh` → `GitHub`、`k8s` → `Kubernetes` 等）を履歴から抽出

### 設計スケッチ

- 既存の `history` テーブルは `input` / `output` で独立しているので、`input: "api", output: "API"` の形でそのまま蓄積できる
- 現実装で `composedHiragana` に英字が入った後の確定処理が `history` に記録されるかを確認（要コード調査）
  されない場合は `commit()` で記録するよう拡張
- prefix マッチ時に履歴の英字エントリも同じく返る（現状の `fetchHistoryPrefix` のまま動くはず）

### リスク

- 誤爆: `api` と打ちたいのに `API` が候補で優先されると、ひらがな入力の妨げになる
  → ASCII 文字列は日本語モードでも特殊扱いのため、誤爆は小さいと見込む（要検証）

### 効果の想定

エンジニア向け・英字混じりドキュメント書きのシーンで効果大。ユースケースは限定的。

---

## 実装優先度

| 案 | 打鍵削減インパクト | 実装コスト | 優先度 |
|----|----|----|----|
| 1. bi-gram プレ候補 | 大（高頻度語の直後すべて） | 中（既存 `doSuggestParticles` 拡張） | ★★★ |
| 2. ゴースト + Tab | 中〜大（履歴依存） | 中〜大（属性付き markedText の挙動調査） | ★★ |
| 3. trigram 拡張 | 中（累積） | 中（スキーマ + 学習フロー） | ★ |
| 4. 英字略語 | 小〜中（用途限定） | 小 | ★ |

**まずは 1 を PLAN 化して着手するのが最短で効果が見える**。2〜4 は 1 の効果を測ったあとに判断。

---

## 計測の枠組み（前提整備）

どの案も効果測定が要る。最小構成で以下を仕込むと比較ができる：

- `InputHandler` に累積カウンタ `totalKeystrokes` / `totalCommittedCharacters` を追加
- 設定画面「Bi-gram」「変換履歴」タブと並べて **「統計」タブ** を追加。
  `committed / keystrokes` 比（打鍵効率）を表示する
- 案を導入する前後で同じユーザー（= 自分）のデータを 1 週間ずつ取って比較

これは案とは別に先行して仕込んでよい（独立に便利）。
