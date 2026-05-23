# keynaco

macOS 向け IME（Input Method Editor）。InputMethodKit + SQLite。

## ドメイン知識

| ドキュメント | 内容 |
|-------------|------|
| [`docs/domain/glossary.md`](docs/domain/glossary.md) | 用語定義・不変条件 |
| [`docs/domain/states.md`](docs/domain/states.md) | 状態遷移図・状態別キー動作 |
| [`docs/domain/scenarios.md`](docs/domain/scenarios.md) | 具体的な入力トレース例 |
| [`docs/domain/architecture.md`](docs/domain/architecture.md) | コンポーネント詳細・Successor モード・候補優先順位 |

**更新ルール**: キー入力の挙動・状態遷移・候補表示ロジックに影響する変更を加えたとき、コードと同じコミットで該当箇所を更新する。
- 用語の定義・不変条件が変わった → `glossary.md`
- 状態遷移・キー動作が変わった → `states.md`
- 入力トレースの具体例が変わった → `scenarios.md`

## ディレクトリ構成

| パス | 内容 |
|------|------|
| `keynaco/` | アプリターゲット（Swift ソース + Info.plist + entitlements + リソース） |
| `keynaco/Settings/` | 設定画面（`SettingsWindowController` 等 8 ファイル。Zenzai タブ含む） |
| `keynaco/Resources/` | バンドルリソース（`zenz-v3.1-small-gguf/` = Zenzai モデル git submodule） |
| `keynaco/Debug/` | デバッグ用ツール（`EventViewerWindow` 等、本番動作には影響しない） |
| `Core/` | Swift Package `KeynacoCore`（入力ロジック・DB・LLM 補助。`Core/Package.swift`） |
| `Core/Sources/CoreTests/` | `KeynacoCore` のユニットテスト（XCTest） |
| `keynacoTests/` | アプリ専用テスト（`SurroundingIMKContext` 等） |
| `keynaco.xcodeproj` | Xcode プロジェクト（リポジトリ管理。ローカル SPM で `Core/` を参照） |
| `docs/domain/` | ドメイン知識ドキュメント（用語・状態遷移・シナリオ） |
| `plans/` | 設計・調査メモ（`PLAN<YYMMDD>.md` 形式） |
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
| `generate_preset_bigram_csv.py` | プリセット bigram データを CSV 生成するスクリプト |

### 起動チェーン（IMK ブートストラップ）

`main.swift` → `NSManualApplication`（`NSApplication` サブクラス）→ `AppDelegate` →
`IMKServer` を生成し `InputController`（`IMKInputController` サブクラス）を登録。
`@objc(ClassName)` アノテーションが必須（後述）。

## ビルド・インストール

`/deploy` スキル（Claude Code 内）でビルドからインストールまで一括実行する。

AzooKey（`AzooKeyKanaKanjiConverter`）が仮名漢字変換の中核エンジン。`Core/Package.swift` で SPM 依存として管理。

- `SWIFT_VERSION: "6.0"`（strict concurrency モード）。新しいクラス・struct を追加する際は `@MainActor`、`Sendable`、または `@unchecked Sendable` のいずれかが必要
- **`@unchecked Sendable` + `Task.detached` の注意**: `@unchecked Sendable` はコンパイラの並行性チェックをバイパスするため、内部の非スレッドセーフな状態を `Task.detached` から触ると無音でデータ競合になる。`AzooKeyConverter.converter`（`KanaKanjiConverter` / Zenzai の `llama_context`）は非スレッドセーフ。`converter.*` を呼ぶメソッドはすべて `converterLock.withLock` を通すこと（過去に SIGABRT クラッシュを引き起こした実績あり）。
- **Zenzai モデルのセットアップ**: `keynaco/Resources/zenz-v3.1-small-gguf/` は HuggingFace の git submodule（LFS 管理）。初回 clone 後に以下が必要:
  ```bash
  brew install git-lfs && git lfs install
  git submodule update --init
  git -C keynaco/Resources/zenz-v3.1-small-gguf lfs pull
  ```
  モデルがなくても Zenzai 機能がオフにフォールバックするだけでビルド自体は通る
- LLM 機能（`LLMSuccessorFetcher` / `LLMSegmentConverter` / `LLMMisconversionChecker`）は `FoundationModels` フレームワーク（Apple Intelligence）を使用。macOS 26 で Apple Intelligence が有効なデバイスでないと `SystemLanguageModel.default.availability` が `.unavailable` を返しスキップされる（IME 基本動作は継続）
- **Apple Intelligence は必須前提**：noun_bigram の蓄積・POS 分類など学習機能のコアは Apple Intelligence に依存する設計。Apple Intelligence なし環境でのフォールバックは論点にしない。

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

[`docs/domain/architecture.md`](docs/domain/architecture.md) を参照。アプリ層（`keynaco/`）が `InputMethodKit` を通じてキーイベントを受け取り、`KeynacoCore`（`Core/`）の `InputHandler` struct でロジックを処理。変換は AzooKey API 経由。候補ウィンドウは自作 `NSWindow`（`CandidateWindow.swift`）。

## テスト方針

- `Core/` の公開型は `public` 必須（`@testable import` はテストのみ有効。App からは `internal` は不可）
- XCUITest / CGEvent は不採用（`typeText()` は IME をバイパス。CGEvent は Accessibility 権限依存で CI 不安定）
- `InputHandler`（純粋 Swift struct）+ `MockTextClient` でユニットテストする
- `ScenarioRegressionTests.swift`: 具体的な入力シーケンス×期待出力のリグレッションテスト。`docs/domain/scenarios.md` と対応
- **E2E 動作確認**: 状態（Successor・Segment・Bracket モード等）に依存する機能変更後は `/keynaco-ime-sandbox` スキルで実機相当の検証を行う（ユニットテストだけではパイプラインのタイミングバグを見逃す）

## キー入力の挙動（特殊ケース）

- **Shift+英字（日本語モード、組成前）**: 英字単語モードを開始（`GitHub` 等の混在ケース用）。`InputHandlerAsciiTests.swift` 参照。
- **英数キー（keyCode 102）**: 組成中なら確定してASCIIモードへ。`ignoreNextModeSwitch` フラグで macOS の二重送信を防ぐ
- **`baseCharacters` vs `characters`**: Shift押下時、`characters`はシフト文字（`>`）、`baseCharacters`は素文字（`.`）。`punctuationMap`は`baseCharacters`で照合するため Shift+`,`/`.` が `<`/`>` になる
- **z シーケンス**: `z` + 記号/矢印キーで特殊文字を挿入（`zCharMap` / `zArrowMap` 定義）。`InputHandlerZSequenceTests.swift` 参照。
- **Bracket モード（`?` / `(` / `[` / `{` / `「`）**: 組成なし・ASCII モードでない状態でトリガー。`bracketOptions` マップで対応文字ペアを定義。US キーボードの `?` は `Shift+/`（`baseCharacters="/"`）なのでキーボード判定が必要（`InputHandler+Candidates.swift` 参照）。

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

`setMarkedText("")`（空文字）のまま候補を表示すると、Electron は「IME が非アクティブ」と判断し Enter をアプリ側で処理する。Successor モード等で候補選択中は実テキストを marked text に設定すること。

### flagsChanged で Caps Lock を検知する

Caps Lock トグルは未実装。実装時は `handle(event:client:)` で `.flagsChanged` イベントを受け取り、`NSEvent.ModifierFlags.capsLock` で ON/OFF を判定する。`inputText` では flagsChanged を受け取れない。

## 不採用の機能

[`docs/rejected.md`](docs/rejected.md) を参照。
