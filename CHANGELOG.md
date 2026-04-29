# Changelog

macOS IME **keynaco** の機能追加・変更・修正のログ。日付降順。

---

## 2026-04-29 — 日時候補の動的追加

### 追加
- **日時候補** — 読みが `きょう` / `きのう` / `あした` / `あす` / `いま` / `ことし` / `きょねん` / `らいねん` / `こんげつ` / `せんげつ` / `らいげつ` のとき、変換候補の末尾（履歴の後・AzooKey 辞書候補の前）に日付・時刻・年の文字列を動的に追加。例: `きょう` → `2026年4月29日` / `4月29日` / `2026-04-29` / `2026/04/29`
- 日時候補を確定しても history / bigram / trigram に記録しない（`commitText(skipHistory:)` 引数で制御）

---

## 2026-04-29 — セグメント境界の学習

### 追加
- **セグメント境界学習（B-1）** — セグメントモードで Shift+矢印による手動境界調整を確定すると、その境界を `boundary_pref` テーブルに保存。次回同じ読みで Space を押すと AzooKey の初期分割ではなく保存済み境界で再現する。上書きポリシーは最後に確定した境界を優先（`ON CONFLICT DO UPDATE`）
- `DatabaseManager` に `saveBoundaryPref` / `fetchBoundaryPref` を追加
- `performGCIfNeeded()` の対象に `boundary_pref` を追加（180日未使用で削除）

> 関連: [PLAN260429e](plans/PLAN260429e.md)

---

## 2026-04-29 — ユーザー辞書・外来音ローマ字拡充・候補品質改善・DB 自動 GC

### 追加
- **ユーザー辞書（F-1）** — 固有名詞を読み（ひらがな）→登録テキストとして永続登録できる `user_dict` テーブルを追加。登録エントリは変換候補の先頭（カナ固定直後・予測より前）に表示。time-decay なし
- 設定画面に「ユーザー辞書」タブを追加（読み+登録テキストの入力フォーム・削除。ひらがなバリデーション付き）
- ステータスバーメニューに「ユーザー辞書...」項目を追加（クリックで直接タブを開く）
- `CandidateAction.show` / `CandidateContext` に `fixedEnd` を追加し、ユーザー辞書行の Shift+Delete 誤削除を防止

---

## 2026-04-29 — 外来音ローマ字拡充・候補品質改善・DB 自動 GC

### 追加
- ゔ行・ウ行拡張（`wu` → `う` 等）・`di` → `でぃ` などの外来音ローマ字テーブルを拡充
- 候補ウィンドウにセクションラベルを表示（固定・履歴・辞書の区別を明示）
- ネガティブフィードバック機能（確定しなかった候補を学習スコアから減衰させる）
- セグメント確定時に bi-gram を記録する仕組み（文節変換の学習品質向上）
- **DB 自動 GC** — `count=1` かつ 180日以上未使用のエントリを全 4 テーブルから削除し `VACUUM` を実行（7日に1回、起動時バックグラウンドで実行）
- **セグメント候補への bi-gram 活用** — `buildSegmentCandidates` が前語コンテキスト（`prev`）を受け取り、`fetchBigram` の結果を固定候補の直後・履歴の前に挿入。セグメント進入時は `lastCommittedOutput` を起点にカスケードで引き継ぎ、右矢印移動時は移動元の選択テキストを prev として次セグメントをリビルド

### 修正
- `fetchHistoryPrefix` で同一出力が複数行返る重複候補を `GROUP BY output` で排除

> 関連: [PLAN260429](plans/PLAN260429.md) · [PLAN260429b](plans/PLAN260429b.md) · [PLAN260429c](plans/PLAN260429c.md) · [IDEA260429](ideas/IDEA260429.md)

---

## 2026-04-28 — 括弧モード・N-gram フィルタ・pendingRomaji 先読み

### 追加
- **括弧モード** — `[` / `(` / `{` 等の括弧キー入力時に全角括弧の候補ウィンドウを表示して選択できる
- **N-gram フィルタ** — Successor 候補を1打目の読み前方一致でフィルタリング（低信頼ペアの誤表示を抑制）
- **高信頼 bi-gram 即時表示** — 閾値（`successorImmediateThreshold` = 5回以上）を超えたペアを確定直後に即時表示
- **pendingRomaji 先読み予測** — 組成前の1文字入力時に bi-gram/trigram/skip-bigram を先読みし、候補があれば Successor モードへ移行

> 関連: [PLAN260428](plans/PLAN260428.md)

---

## 2026-04-27 — 学習強化・Successor チェーン・イベントビューアー

### 追加
- **trigram** — 2語前コンテキストを使った予測で変換精度を向上
- **英字単語モード** — 日本語モードのまま `GitHub` 等の混在ケース英語を入力可能
- **ASCII 英字学習** — 英字入力を変換履歴として記録し候補表示に反映
- **`recordPrefixes`** — 読み省略パターン（`東京` → `とう` / `とうきょ` 等）を自動学習
- **文節 Space 確定学習** — セグメントモードで Space 確定したフレーズ全体を bi-gram/trigram として記録
- **skip-bigram** — 助詞をまたいだ語間（`東京` → `行く` 等）を学習
- **時間減衰スコアリング** — `count / (1 + age_days / 30)` を全 fetch SQL に適用し古い履歴を自然に降格
- **Successor チェーン** — 候補確定後に次の bi-gram 候補があれば連続して候補を表示
- **文末リセット** — 句点・感嘆符・疑問符・改行確定時に `committedHistory` をクリアし文をまたぐ n-gram 学習を防止
- **イベントビューアー** — メニューバー常駐ウィンドウ（⌨アイコン）でキーコード・確定テキスト・候補をリアルタイム表示。JSONL エクスポート対応

### 修正
- `nn` → `ん` 後の pending `n` を不可視化する標準 IME 準拠挙動（`hiddenPendingN`）
- 入力ソースアイコンのキー名・フォーマット（TIFF）と、キーボード設定での表示名を修正

> 関連: [PLAN260427](plans/PLAN260427.md) · [PLAN260427b](plans/PLAN260427b.md) · [PLAN260427c](plans/PLAN260427c.md) · [PLAN260427d](plans/PLAN260427d.md) · [PLAN260427e](plans/PLAN260427e.md)

---

## 2026-04-20 — Successor モード一般化

### 変更
- 格助詞モード（`isParticleMode`）を **`isSuccessorMode`** にリネームし、格助詞に限らず全確定語の直後に bi-gram 予測を表示するよう拡張
- 格助詞リストのフォールバック表示は名詞（漢字・カタカナ末尾）直後のみに制限

> 関連: [PLAN260420](plans/PLAN260420.md)

---

## 2026-04-18〜19 — keynaco リネーム・設定 UI・格助詞予測

### 追加
- プロダクト名を **ykey → keynaco** にリネーム
- アプリアイコンと `make_icons.swift` による自動生成スクリプト
- `git tag` からバージョン番号を `CFBundleShortVersionString` / `CFBundleVersion` に自動注入（post-action）
- AzooKeyKanaKanjiConverter をリモート SPM 依存に切り替え（v0.11.2）
- **格助詞クイック選択** — 確定直後に格助詞リスト（を・に・で・へ・と…）を自動表示し、頭文字1打で即確定
- **設定画面** — bi-gram エクスポート/インポート・変換履歴一覧・bi-gram 一覧・削除 UI（`NSTabViewController`）
- `TISRegisterInputSource` による起動時の自動登録
- 候補選択中の右矢印でひらがな組成に戻す（Electron 系アプリでの Enter 問題を回避）

> 関連: [PLAN260418](plans/PLAN260418.md)

---

## 2026-04-17 — AzooKey 変換エンジン移行

### 追加
- 履歴の前方一致補完（入力中に補完候補をリアルタイム表示）
- 辞書候補の自動表示（2文字以上のひらがな入力で発動）
- Shift+Delete で選択中の履歴候補を変換履歴 DB から削除
- 候補ウィンドウに履歴/辞書の区別を視覚表示（セパレーター行）

### 変更
- 変換エンジンを SKK-JISYO-L / mozc システム辞書から **AzooKeyKanaKanjiConverter** に移行（組み込み辞書使用）

### 削除
- mozc システム辞書・ビルドスクリプト・okuri-ari 展開スクリプト
- SKK-JISYO-L 関連ファイル

> 関連: [PLAN260417](plans/PLAN260417.md)

---

## 2026-04-12 — 文節変換・カタカナ候補・句読点変換

### 追加
- **文節（ぶんせつ）変換モード** — Space で AzooKey 変換を起動し、Shift+矢印でセグメント境界を1文字単位で調整
- **カタカナ固定候補** — 候補リスト先頭にカタカナ変換を挿入（F7 と同等の候補をワンクリックで選択可）
- 句読点変換 — `,` → `、` / `.` → `。`（かなモード中のみ）
- 組成中に句読点を入力したとき候補ウィンドウを開く
- `InputHandler` を `InputController` から分離し XCTest によるユニットテストを可能にした

> 関連: [PLAN260412](plans/PLAN260412.md) · [PLAN260412b](plans/PLAN260412b.md)

---

## 2026-04-11 — ビルド自動化・テスト基盤

### 追加
- Xcode scheme post-action によるビルド→`/Library/Input Methods/` への自動コピーとプロセス再起動
- `CompositionState`（未確定文字列の状態）を `InputController` から分離しテスト可能に

> 関連: [PLAN260411](plans/PLAN260411.md)

---

## 2026-03-14 — 初期実装

### 追加
- macOS 向け IME の初期実装（InputMethodKit + SQLite、Swift 6 strict concurrency）
- ローマ字→ひらがな変換（`RomajiConverter`）
- SKK 辞書による漢字変換（後の 2026-04-17 で AzooKey に移行）
- カスタム候補ウィンドウ（`NSWindow(.borderless)` + `NSTableView`、`IMKCandidates` は非採用）
- 矢印キー・Shift+Tab による候補ナビゲーション
- 英数/かなキーによる ASCII モード切り替え（`isAsciiMode` はアプリをまたいでグローバルに保持）

> 関連: [IDEA260327](ideas/IDEA260327.md)
