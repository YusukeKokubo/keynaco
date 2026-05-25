# アーキテクチャ詳細

CLAUDE.md の「コンポーネント構成」の詳細リファレンス。

## コンポーネント一覧

- `InputController` = IMK ブリッジ（NSEvent 展開 → InputHandler 委譲）。`CandidateWindow` もここで管理
- `InputHandler` = 入力ロジック本体（テスト可能）、Swift 6 strict concurrency。実装は機能ごとに extension 分割: `InputHandler+NormalInput.swift`（通常キー処理・ASCII/かなモード切替）、`InputHandler+Candidates.swift`（候補リスト構築）、`InputHandler+DateTime.swift`（日時候補生成）、`InputHandler+Numbers.swift`（数字入力時の全角・桁区切り候補生成）、`InputHandler+SegmentMode.swift`（文節調整）。`isAsciiMode` は `static` — 全インスタンス共有でアプリ切替後もモードを維持。テストの `setUp` でリセット必須。`isBracketMode`（`bracketCandidates != nil`）: `[`/`(`/`!`/`?`/`/`/`.`/`,` 等の記号キーを**待機中**（組成空）に入力したとき、対応する全角候補ウィンドウを表示するモード（`bracketOptions` マップで ASCII 記号 → 全角候補列に変換。`"?": ["？", "?"]`・`"!": ["！", "!"]`・`"/": ["・", "／", "/"]`・`".": ["。", "．", "…"]`・`",": ["、", "，"]` 等、記号全般に対応）。`sentenceTerminators`（`["。", "！", "？"]`）確定時に `committedHistory.removeAll()` を呼び、文をまたいだ n-gram 学習を防止する（Enter キー空確定時は別途 `removeAll()`）。**句読点（`readingPunctuations`）確定時は `recordPrefixes` をスキップし** `pushCommitted` でも `committedHistory` に追加しない（句読点が next-word 予測を汚すのを防ぐ）
- `TextInputClient` = `insertText` / `setMarkedText` を抽象化するプロトコル（テストでは `MockTextClient`、本番では IMK クライアントをラップ）
- `CompositionState` = 未確定文字列の状態（composedHiragana + pendingRomaji）、ローマ字→ひらがな変換を内包。`hiddenPendingN` フラグで "nn" → "ん" 後の pending "n" を不可視化（標準 IME 準拠）。Backspace 時は "ん" + hidden n をまとめて1操作で削除する
  - `SegmentState`（`segmentState`）を持ち `isSegmentMode` が true の間はセグメント調整モード。Space 押下時に AzooKey の変換結果をセグメント分割して遷移
- `RomajiConverter` = ローマ字→ひらがな変換ルールの実装
- `AzooKeyConverting` / `AzooKeyConverter` = ひらがな→漢字変換エンジンの DI プロトコルと実装（`TextInputClient` と同じ役割）。`AzooKeyConverter` は `KanaKanjiConverterModuleWithDefaultDictionary` のラッパー（学習データを `~/Library/Application Support/keynaco/` に保存）。`isZenzaiEnabled` はユーザー設定（モデル未ロード時も true になり得る）。`buildCandidateList` は `composedHiragana` が変わらない限り `requestCandidates` を再呼び出しせずキャッシュを返す（LRU 上限 50 件）
- `DatabaseManager` = 変換履歴の記録・参照・削除（SKK辞書検索ではない）。機能ごとに extension 分割: `+History.swift`（履歴 fetch/record）、`+UserDict.swift`（ユーザー辞書 CRUD）。`InputHandler` のイニシャライザで DI（テストは `inMemory: true`）。`history` / `user_dict` / `hiragana_preferred` の **3 テーブル**を持つ。起動時に廃止テーブル `bigram` / `trigram` / `skip_bigram` / `boundary_pref` / `noun_bigram` / `content_bigram` を `DROP` する（既存 DB のマイグレーション用。現行コードはこれらを参照しない）。実 DB は `~/Library/Application Support/keynaco/history.db`。SQLite 定型句は private ヘルパー `queryStrings` / `execute`（クロージャ方式）に集約。全 fetch/record で `nowEpoch()`（`clock` var 経由）を使い時間減衰スコア `count / (1 + age_days / τ)` でソート（τ=30日）。`user_dict` のみ time-decay なし（永続登録）。`performGCIfNeeded()` で `history` の count=1 かつ 180日超のエントリを定期削除。**設計不変条件**: `recordPrefixes` はフル読みのみ1行記録（プレフィックス展開なし）。文節単位の学習は Space → セグメントモード確定時のみ（通常 Enter 確定は合成読み×出力の1行のみ）。`fetchHistoryScoredMerged` は `LIKE 'reading%'` で exact + 前方一致を一括取得し `GROUP BY output` の `SUM` で集計する（exact/prefix を別クエリに分離して `MAX` で合計する設計は NG — 異なる読み長で確定した回数が合算されなくなる）
- `sessionTextBuffer` = Zenzai 左文脈用のインメモリ文字列バッファ（上限 50 字）。`commitText` で確定テキストを追記（読点 `、` 等の `readingPunctuations` はスキップ、文末 `。` 等は追記）。`sentenceTerminators` 確定時は `committedHistory` のみクリアしバッファは維持。ASCII Enter・組成なし Enter・`activateServer` でバッファもクリア。`InputController.resolvedLLMDocumentContextPrefix` が IMK `before` と結合する素材として使う
- `SettingsWindowController` / `HistoryViewController` / `UserDictViewController` / `HiraganaPreferredViewController` / `CleanserSheetViewController` / `ZenzaiViewController` = `keynaco/Settings/` 配下の設定画面。`NSTabViewController` で「ユーザー辞書」「ひらがな優先」「変換履歴」「Zenzai」の **4 タブ**を提供。ユーザー辞書は読み（ひらがな）→登録テキストの CRUD。`CleanserSheetViewController` は変換履歴の AI スキャン用シート
- `ZenzaiSettings` / `ZenzaiViewController` = `keynaco/Settings/` 配下の Zenzai 設定。有効フラグ・プロフィール文字列・推論トークン上限を `UserDefaults` 経由で保存。`AzooKeyConverter.isZenzaiEnabled` が参照する
- `CandidateAction` / `CandidateContext` = `InputHandler` が返す候補ウィンドウ操作指示と状態スナップショット。`isExplicitlySelected`（↑↓で動かしたか）と `historyEnd`（固定+ユーザー辞書+予測+履歴セクションの末尾インデックス）と `fixedEnd`（カナ固定+ユーザー辞書の末尾インデックス。`fixedEnd <= row < historyEnd` の行が Shift+Delete 可能）が重要
- `CandidateWindow` = `keynaco/CandidateWindow.swift`。`NSPanel(.borderless, level: .popUpMenu)` + `NSTableView` の自作候補ウィンドウ。`IMKCandidates` は macOS 26 で動作しないため自作（詳細は CLAUDE.md「macOS 26 IME の罠」参照）。`InputController` が所有・制御する。候補が 8 件以下のときはウィンドウ高さを全件分取り、スクロール位置は先頭（`initialRow` より前の行も見える）。9 件以上のときだけ `initialRow` を上端に合わせる
- `AppDelegate` = `IMKServer` 起動 + `setupMainMenu()`（Edit メニュー登録。アクセサリアプリは既定でメインメニューを持たず Cmd+V/A/Z が届かないため）
- `SurroundingIMKContext` = カーソル前後テキストの取得ユーティリティ（enum + static func）。`IMKTextInput` の `attributedSubstring(from:)` / `length` / `selectedRange` をラップし、LLM 系コンポーネント（`LLMPOSClassifier` 等）が文脈テキストを取得するために使用
- `InputHandlerSnapshot`（`#if DEBUG`）= `InputController` が `InputHandler` と候補ウィンドウから組み立てるデバッグ用スナップショット（`InputHandlerSnapshot.swift` + `InputHandler+Snapshot.swift`）。`DebugSocketServer` が JSON レスポンスのペイロードとして送信
- `EventViewerWindow` = `keynaco/Debug/EventViewerWindow.swift`。`AppDelegate` が NSStatusItem（⌨アイコン）として常駐し、メニューから起動。keyCode・chars・mods・consumed・action・app をリアルタイム表示。確定テキストと候補リストをキャプチャしてクリップボードにコピー可能。JSONL エクスポートで `~/Library/Application Support/keynaco/sessions/` に保存。デバッグ用途
- `IMESandboxWindow` = `keynaco/Debug/IMESandboxWindow.swift`。GUI 上でキーシーケンスを手動送信し `DebugSocketServer` の状態スナップショットを表示するサンドボックス画面。`AppDelegate` からメニュー経由で起動
- `DebugSocketServer` = `keynaco/Debug/DebugSocketServer.swift`（`#if DEBUG`）。Unix ドメインソケット（`$TMPDIR/keynaco-debug.sock`）経由でキー入力コマンドを受け取り、専用 `InputHandler`（`DatabaseManager(inMemory: true)`）で処理して JSON を返す対話デバッグサーバー。IMK パイプラインをバイパスするため本番アプリとは独立。`/keynaco-ime-sandbox` スキルが使用。サンドボックスプロトコルは以下のコマンドを持つ: `key`（キー送信）、`reset`（状態リセット）、`seed`（DB シード）、`fields`（レスポンスフィルタ）、`assert`（値アサーション）、`assert_schema`（型スキーマ検証）、`assert_regex`（正規表現アサーション）、`assert_eventually`（非同期待機アサーション）、`wait_until`（条件待機）、`capture`（変数キャプチャ）、`run_suite`（シナリオスイート実行。`before_each`/`after_each` フック・fail-fast・ステップラベル対応）、`lint_suite`（スイートの静的検証）。レスポンスには `explain` サマリー・候補の `diff`・メタデータが含まれる

変換エンジンは `AzooKeyKanaKanjiConverter`（`Core/Package.swift` の依存）の組み込み辞書を使用。SQLite は変換履歴のみ管理する。
カタカナ候補は `hiraganaToKatakana` で自動生成し、変換候補の先頭（履歴より後）に差し込む。
`KanaUtils` = ひらがな↔カタカナ変換ユーティリティ（`hiraganaToKatakana` / `hiraganaToHankakuKatakana` / `toZenkakuAscii`）。F7–F9 変換確定とカタカナ候補生成で使用。
## 候補表示の優先順位

`buildCandidateList()` が組み立てる候補リスト（上が高優先）:

1. ひらがな / カタカナ固定候補（`hiraganaPreferred`・外来語記号・**autoShow 時の辞書のみ変換**で先頭に挿入。後者は履歴・予測・ユーザー辞書・数値/日時が無いとき読みのひらがなを row 0 に置き、読みのカタカナ表記は辞書ブロックから除外する）
2. **ユーザー辞書**候補（完全一致のみ、`fixedCount` の直後に挿入）
3. **Zenzai top-1**（`azooKeyConverter.isZenzaiEnabled` かつ左文脈ありのときのみ、ユーザー辞書の直後に AzooKey 候補先頭を 1 行固定。`isZenzaiEnabled` はユーザー設定でありモデル未ロード時も true になり得る。辞書ブロックからは同じ表層を除く）
4. 履歴（`fetchHistoryScoredMerged`：`LIKE 'reading%'` で全読みを統合 SUM 集計。時間減衰スコアが閾値 **以上**の行のみ。このブロックの件数が `historyEnd` 計算の履歴件数）
5. 数字候補（`generateNumberCandidates`：全角数字 + 桁区切り。数字のみ入力時に生成、`historyEnd` の直後に挿入。変換履歴には記録しない）
6. 日時候補（`generateDateTimeCandidates`：きょう/いま/ことし等、数字候補の直後に挿入。変換履歴には記録しない）
7. AzooKey 辞書候補（プロモート済み top-1 は除外済み）

`autoShow=true`（文字入力中の自動表示）のとき、高スコア履歴・辞書・ユーザー辞書がすべて 0 件なら表示しない。

Shift+Delete 可能な範囲: `fixedEnd <= row < historyEnd`（`fixedCount <= row < fixedEnd` のユーザー辞書行・Zenzai プロモート行は削除不可。`CandidateAction.fixedEnd` は Zenzai 行を含む）。

## handler フィールドのライフサイクル

`InputController` が `handler.handle()` の前後でセットする handler フィールドは 2 種類に分かれる。

| タイミング | 例 | 理由 |
|------|----|----|
| **handle の前** | `leftSideContext` | `handle` 内（`buildCandidateList` 等）から読まれる |
| **handle の後**（`applyPostKeyDownEffects`） | `cachedSurroundingContext` 更新・候補ウィンドウ更新 | 次キー以降のための準備 |

**判定基準**: そのフィールドが現在のキー処理中に参照されるなら pre、次以降のキー処理 or 非同期コールバックでのみ参照されるなら post。post に置くと「1 キーストローク遅延」バグになる。

**組成判定の軸**: 「組成中かどうか」を扱う条件は `composedHiragana` ではなく `composingText`（= `composedHiragana + pendingRomaji`）を見る。
