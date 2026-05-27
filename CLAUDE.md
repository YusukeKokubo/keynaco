# keynaco

macOS 向け IME（Input Method Editor）。InputMethodKit + SQLite。

## ドメイン知識

| ドキュメント | 内容 |
|-------------|------|
| [`docs/domain/glossary.md`](docs/domain/glossary.md) | 用語定義・不変条件 |
| [`docs/domain/states.md`](docs/domain/states.md) | 状態遷移図・状態別キー動作 |
| [`docs/domain/scenarios.md`](docs/domain/scenarios.md) | 具体的な入力トレース例 |
| [`docs/apple-intelligence.md`](docs/apple-intelligence.md) | FoundationModels の制約・実験結果・使いどころ |

**更新ルール**: キー入力の挙動・状態遷移・候補表示ロジックに影響する変更を加えたとき、コードと同じコミットで該当箇所を更新する。
- 用語の定義・不変条件が変わった → `glossary.md`
- 状態遷移・キー動作が変わった → `states.md`
- 入力トレースの具体例が変わった → `scenarios.md`

## ディレクトリ構成

| パス | 内容 |
|------|------|
| `keynaco/` | アプリターゲット（Swift ソース + Info.plist + entitlements + リソース） |
| `keynaco/Settings/` | 設定画面（`SettingsWindowController` 等 9 ファイル。ユーザー辞書・ひらがな優先・変換履歴・Zenzai・NAS 同期・日記の 6 タブ） |
| `keynaco/Resources/` | バンドルリソース（`zenz-v3.1-small-gguf/` = Zenzai モデル git submodule） |
| `keynaco/Debug/` | デバッグ用ツール（`DebugSocketServer`・`DebugCandidateWindow`・`EventViewerWindow`・`IMESandboxWindow`・`SocketMockClient` 等、本番動作には影響しない） |
| `Core/` | Swift Package `KeynacoCore`（入力ロジック・DB・LLM 補助。`Core/Package.swift`） |
| `Core/Sources/Core/` | `KeynacoCore` の実装（`InputHandler` 等） |
| `Core/Sources/CoreTests/` | `KeynacoCore` のユニットテスト（XCTest） |
| `keynacoTests/` | アプリ専用テスト（`SurroundingIMKContext` 等） |
| `keynaco.xcodeproj` | Xcode プロジェクト（リポジトリ管理。ローカル SPM で `Core/` を参照） |
| `docs/` | `principles.md`（設計原則）・`rejected.md`（不採用機能）・`domain/`（用語・状態遷移・シナリオ） |
| `plans/` | 設計・調査メモ（`PLAN<YYMMDD>.md` / `POC<YYMMDD>.md` 形式） |
| `scripts/` | 開発用スクリプト（下記参照） |
| `ideas/` | アイデアメモ（`IDEA<YYMMDD>.md` 形式） |
| `make_icons.swift` | アイコン素材を各サイズに切り出すスクリプト |
| `issues/` | バグ・課題メモ（`ISSUE<YYMMDD>.md` 形式） |

### スクリプト一覧（`scripts/`）

| スクリプト | 用途 |
|-----------|------|
| `debug_ime.py` | デバッグソケット（`$TMPDIR/keynaco-debug.sock`）クライアント（キーシーケンス手動送信） |
| `repro_AB_storm_once.py` | A→B→新規接続リセット時のクラッシュ再現スクリプト |
| `repro_debug_socket_stress.py` | ソケットのストレステスト・ECONNREFUSED 切り分け用 |

### 起動チェーン（IMK ブートストラップ）

`main.swift` → `NSManualApplication`（`NSApplication` サブクラス）→ `AppDelegate` →
`IMKServer` を生成し `InputController`（`IMKInputController` サブクラス）を登録。

## ビルド・インストール

`/deploy` スキル（Claude Code 内）でビルドからインストールまで一括実行する。手動でビルドのみ行う場合:

```bash
xcodebuild build -scheme keynaco -destination "platform=macOS"
```

- `SWIFT_VERSION: "6.0"`（strict concurrency モード）。新しいクラス・struct を追加する際は `@MainActor`、`Sendable`、または `@unchecked Sendable` のいずれかが必要
- **`@unchecked Sendable` + `Task.detached` の注意**: `@unchecked Sendable` はコンパイラの並行性チェックをバイパスするため、内部の非スレッドセーフな状態を `Task.detached` から触ると無音でデータ競合になる。`AzooKeyConverter.converter`（`KanaKanjiConverter` / Zenzai の `llama_context`）は非スレッドセーフ。`converter.*` を呼ぶメソッドはすべて `converterLock.withLock` を通すこと（過去に SIGABRT クラッシュを引き起こした実績あり）。
- **Zenzai モデルのセットアップ**: `keynaco/Resources/zenz-v3.1-small-gguf/` は HuggingFace の git submodule（LFS 管理）。初回 clone 後に以下が必要:
  ```bash
  brew install git-lfs && git lfs install
  git submodule update --init
  git -C keynaco/Resources/zenz-v3.1-small-gguf lfs pull
  ```
  モデルがなくても Zenzai 機能がオフにフォールバックするだけでビルド自体は通る
- POS 分類（`AzooKeyPOSClassifier`）は AzooKey 辞書の `lcid` + 接続詞/感動詞辞書によるルールベース実装。Apple Intelligence 不要。起動時に `AzooKeyPOSBackfill` で未分類エントリを一括再分類する。以前の `LLMPOSClassifier`（FoundationModels）は精度壊滅（77% が `other`）のため削除済み（`plans/PLAN260525c.md` 参照）。`LLMSegmentConverter`（セグメントモード LLM 補助）は Zenzai ON 環境での効果がなく削除済み。

### Zenzai 制御パラメータ（zenz-v3 の条件付き変換）

zenz-v3 は制御トークンを使って変換確率分布をバイアスする「条件付き変換モデル」。各パラメータは最大 25 文字で、キーワードを `,` 区切りで書くのが効率的。

| パラメータ | 制御トークン | 役割 | 効果的な入力例 |
|-----------|------------|------|--------------|
| `profile` | `\u{EE03}` | 執筆者の属性 | `ITエンジニア,技術文書` |
| `topic`   | `\u{EE04}` | 執筆内容・話題 | `料理,レシピ` |
| `style`   | `\u{EE05}` | 文体・トーン | `ですます,箇条書き` |
| `preference` | `\u{EE06}` | ユーザー固有の癖 | `旧字体優先` |

- **効果が出やすい**: 専門職（`医師`・`弁護士`）、特定分野（`競馬`・`アニメ`）、文体（`SNS`・`2ch`）。同音異義語の選択が変わる
- **効果が出にくい**: 個人名（`田中太郎`）、挨拶文、汎用的すぎる語（`普通の人`）
- keynaco は現在 `profile` のみ UI に露出。`topic`/`style`/`preference` は zenz-v3.1-small では測定可能な効果がないため UI から削除済み（`plans/POC260524.md` 参照）。AzooKey API 自体は引き続きサポートしているが、keynaco では使用しない。

## テスト実行

アプリ＋ IMK 関連テスト:

```bash
xcodebuild test -scheme keynaco -destination "platform=macOS"
```

コアロジックのみ（`KeynacoCore` / SPM）:

```bash
cd Core && swift test
```

末尾に `✔ Test run with 0 tests in 0 suites passed` が出るが正常（Swift Testing framework のノイズ）。XCTest の結果は `Executed N tests` として別途出力される。

## コンポーネント構成

アプリ層（`keynaco/`）が `InputMethodKit` を通じてキーイベントを受け取り、`KeynacoCore`（`Core/`）の `InputHandler` struct（Swift 6 strict concurrency）でロジックを処理。変換は AzooKey API（`AzooKeyConverter`）+ Zenzai 経由、履歴は SQLite（`DatabaseManager`）、候補ウィンドウは自作 `NSWindow`（`CandidateWindow.swift`）。

- `InputController` = IMK ブリッジ（NSEvent 展開 → InputHandler 委譲）。`CandidateWindow` を所有
- `InputHandler` = 入力ロジック本体。機能別 extension 分割（`+NormalInput` / `+Candidates` / `+DateTime` / `+Numbers` / `+SegmentMode` / `+BracketMode`）。`isAsciiMode` は `static` で全インスタンス共有（テストの `setUp` でリセット必須）
- `CompositionState` = `composedHiragana + pendingRomaji`。`hiddenPendingN` で `nn`→`ん` 後の pending `n` を不可視化（Backspace は `ん`+hidden n をまとめて1操作で削除）
- `AzooKeyConverter` = ひらがな→漢字変換のラッパー。`buildCandidateList` は `composedHiragana` 不変ならキャッシュ返却（LRU 50 件）
- `DatabaseManager` = `history` / `user_dict` / `hiragana_preferred` / `daily_log` / `diary` の 5 テーブル。時間減衰スコア `count / (1 + age_days / 30)` でソート（`user_dict` のみ time-decay なし）。詳細不変条件はコード側コメント参照
- `sessionTextBuffer` = Zenzai 左文脈バッファ（上限 50 字）。`readingPunctuations` はスキップ、`sentenceTerminators` 確定でも `committedHistory` のみクリアしバッファは維持
- `CandidateWindow` = `NSPanel(.borderless, level: .popUpMenu)` + `NSTableView`。`IMKCandidates` は macOS 26 で不安定なため自作

### 候補表示の優先順位（`buildCandidateList`）

1. ひらがな / カタカナ固定（`hiraganaPreferred`・外来語記号）
2. ユーザー辞書（完全一致）
3. Zenzai top-1（`isZenzaiEnabled` かつ左文脈ありのみ）
4. 履歴（`fetchHistoryScoredMerged`: `LIKE 'reading%'` で SUM 集計、時間減衰スコア閾値以上）
5. 数字候補（`generateNumberCandidates`）
6. 日時候補（`generateDateTimeCandidates`）
7. AzooKey 辞書候補（Zenzai プロモート済みは除外）

`fixedEnd <= row < historyEnd` の行のみ Shift+Delete で履歴 DB から削除可能（ユーザー辞書・Zenzai プロモート行は保護）。

### handler フィールドのライフサイクル

`InputController` が `handler.handle()` の前後でセットするフィールドは 2 種類:
- **pre**（`handle` の前）: `leftSideContext` 等、`handle` 内から読まれる
- **post**（`applyPostKeyDownEffects`）: `cachedSurroundingContext` 等、次キー以降のための準備

判定基準: 現在のキー処理中に参照されるなら pre、次以降のキー処理 or 非同期コールバックでのみ参照されるなら post。post に置くと「1 キーストローク遅延」バグになる。

組成判定の軸は `composedHiragana` ではなく `composingText`（= `composedHiragana + pendingRomaji`）。

## テスト方針

- `InputHandler`（純粋 Swift struct）+ `MockTextClient` でユニットテストする
- `ScenarioRegressionTests.swift`: 具体的な入力シーケンス×期待出力のリグレッションテスト。`docs/domain/scenarios.md` と対応
- **E2E 動作確認**: 状態（Segment・Bracket モード等）に依存する機能変更後は `/keynaco-ime-sandbox` スキルで実機相当の検証を行う（ユニットテストだけではパイプラインのタイミングバグを見逃す）。sandbox で通常文字を送るには `{"type_string": "k"}` を使う（`{"key": "k"}` は特殊キーのみ有効）

## キー入力の挙動（特殊ケース）

- **Shift+英字（日本語モード、組成前）**: 英字単語モードを開始（`GitHub` 等の混在ケース用）。`InputHandlerAsciiTests.swift` 参照。
- **英数キー（keyCode 102）**: 組成中なら確定してASCIIモードへ。`ignoreNextModeSwitch` フラグで macOS の二重送信を防ぐ
- **`baseCharacters` vs `characters`**: Shift押下時、`characters`はシフト文字（`>`）、`baseCharacters`は素文字（`.`）。Shift+`,`/`.` は `characters` が `<`/`>` となり Bracket モード（`＜`/`＞` 候補）に入る
- **z シーケンス**: `z` + 記号/矢印キーで特殊文字を挿入（`zCharMap` / `zArrowMap` 定義）。`InputHandlerZSequenceTests.swift` 参照。
- **Bracket モード（`?` / `(` / `[` / `{` / `「` / `,` / `.` 等）**: 組成なし・ASCII モードでない状態でトリガー。`bracketOptions` マップで対応文字ペアを定義。US キーボードの `?` は `Shift+/`（`baseCharacters="/"`）なのでキーボード判定が必要（`InputHandler+Candidates.swift` 参照）。

## macOS 26 IME の罠

### Bundle ID に "inputmethod" が必須（InputMethodKit 全般の仕様）

TIS がサードパーティ IME を認識するために Bundle ID に `inputmethod` の文字列が必要（macOS 26 固有ではなく InputMethodKit 長年の仕様）。これがないと `TISRegisterInputSource` は成功を返すが `TISCreateInputSourceList` に現れない。サイレントに失敗するため原因特定が極めて困難。

### inputText より handle(event:client:) を使う

`inputText(_:key:modifiers:client:)` は矢印キー等の特殊キーを受け取れない。`handle(_ event: NSEvent!, client sender: Any!) -> Bool` をオーバーライドすること。

### Swift クラスに @objc が必須

InputMethodKit は ObjC ランタイムでクラスを探す。Swift の `IMKInputController` サブクラスや `NSApplication` サブクラスには `@objc(ClassName)` を付けないと実行時に見つからない。Info.plist のクラス名もモジュールプレフィックスなしにする（`keynaco.InputController` ではなく `InputController`）。

### IMKCandidates は macOS 26 で動作しない（実体験）

`IMKCandidates` の `selectCandidate(withIdentifier:)` が macOS 26 環境で動作しなかった（Apple 公式の明示的なバグ報告はないが、歴史的に描画不安定の報告が多い）。候補ウィンドウは `NSWindow(.borderless, level: .popUpMenu)` + `NSTableView` で自作する。

### Development 署名で spctl -a は "rejected" になる

正常動作する。Gatekeeper の仕様であり問題ない。

### Electron 系アプリで Enter が届かない

`setMarkedText("")`（空文字）のまま候補を表示すると、Electron は「IME が非アクティブ」と判断し Enter をアプリ側で処理する。候補選択中は実テキストを marked text に設定すること。

### flagsChanged で Caps Lock を検知する

Caps Lock トグルは未実装。実装時は `handle(event:client:)` で `.flagsChanged` イベントを受け取り、`NSEvent.ModifierFlags.capsLock` で ON/OFF を判定する。`inputText` では flagsChanged を受け取れない。

## 不採用の機能

[`docs/rejected.md`](docs/rejected.md) を参照。

## 設計判断の原則

[`docs/principles.md`](docs/principles.md) を参照。新機能の実装前・大きなリファクタリング前に読み返す。
