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
| `keynaco/PresetBigram/` | `preset_bigram.csv`（プリセット Bi-gram バンドルリソース） |
| `keynaco/Debug/` | デバッグ用ツール（`EventViewerWindow` 等、本番動作には影響しない） |
| `Core/` | Swift Package `KeynacoCore`（入力ロジック・DB・LLM 補助。`Core/Package.swift`） |
| `Core/Sources/CoreTests/` | `KeynacoCore` のユニットテスト（XCTest） |
| `keynacoTests/` | アプリ専用テスト（`CandidateWindow` / `SurroundingIMKContext` 等） |
| `keynaco.xcodeproj` | Xcode プロジェクト（リポジトリ管理。ローカル SPM で `Core/` を参照） |
| `docs/domain/` | ドメイン知識ドキュメント（用語・状態遷移・シナリオ） |
| `plans/` | 設計・調査メモ（`PLAN<YYMMDD>.md` 形式） |
| `scripts/` | 開発用スクリプト（下記参照） |
| `ideas/` | アイデアメモ（`IDEA<YYMMDD>.md` 形式） |
| `make_icons.swift` | アイコン素材を各サイズに切り出すスクリプト |
| `LocalPackages/` | Xcode ローカルパッケージ参照（`keynacoCore/`）。Xcode が管理するため手動編集不要 |

### スクリプト一覧（`scripts/`）

| スクリプト | 用途 |
|-----------|------|
| `generate_preset_bigram_csv.py` | `preset_bigram.csv` 生成 |
| `debug_ime.py` | デバッグソケットの Python クライアント（キーシーケンス手動送信） |
| `repro_AB_storm_once.py` | A→B→新規接続リセット時のクラッシュ再現スクリプト |
| `repro_debug_socket_stress.py` | ソケットのストレステスト・ECONNREFUSED 切り分け用 |

### 起動チェーン（IMK ブートストラップ）

`main.swift` → `NSManualApplication`（`NSApplication` サブクラス）→ `AppDelegate` →
`IMKServer` を生成し `InputController`（`IMKInputController` サブクラス）を登録。
`@objc(ClassName)` アノテーションが必須（後述）。

## ビルド・インストール

```bash
xcodebuild build -scheme keynaco -configuration Debug
```

- Build Post-action（`keynaco` scheme の Build Post-action、`keynaco.xcodeproj` 内）により `/Library/Input Methods/` への自動コピーとプロセス再起動が行われる
- ビルド後の `Warning: unknown environment variable SWIFT_DEBUG_INFORMATION_FORMAT` は無害。`rm: /Library/Input Methods/keynaco.app: Permission denied` も正常（post-action は sudo なしでは Copy できないが BUILD SUCCEEDED は正しい）
- `SWIFT_VERSION: "6.0"`（strict concurrency モード）。新しいクラス・struct を追加する際は `@MainActor`、`Sendable`、または `@unchecked Sendable` のいずれかが必要
- バージョン番号は git tag で管理。`git tag v0.1.0` → ビルド時に `CFBundleShortVersionString` / `CFBundleVersion` に自動注入（post-action が `PlistBuddy` で書き換え）。`PlistBuddy` 後は署名が無効化されるため、post-action の最後で `codesign --force --deep --sign` による再署名が必須（無いと macOS 26 が SIGKILL でプロセスを落とす）
- 初回セットアップ: `sudo chmod -R +a "$(whoami) allow list,add_file,search,add_subdirectory,delete_child,delete,read,write,execute" "/Library/Input Methods"` が必要（所有者を root のまま ACL で自分にだけ権限を付与）
- **Zenzai モデルのセットアップ**: `keynaco/Resources/zenz-v3.1-small-gguf/` は HuggingFace の git submodule（LFS 管理）。初回 clone 後に以下が必要:
  ```bash
  brew install git-lfs && git lfs install
  git submodule update --init
  git -C keynaco/Resources/zenz-v3.1-small-gguf lfs pull
  ```
  モデルがなくても Zenzai 機能がオフにフォールバックするだけでビルド自体は通る（Xcode プロジェクトからリソース参照を削除した場合）
- `~/Library/Input Methods/` は使わない（入力ソースが重複登録される）
- 初回インストール後、ログアウト→ログインで反映。System Settings → キーボード → 入力ソース → 英語 で追加
- 起動のたびに `TISRegisterInputSource` を呼んで入力ソースを自動登録する。初回のみログアウト→ログインが必要（TIS がキャッシュを更新するため）
- `/deploy` スキル（Claude Code 内）: ビルドからインストールまでを一括実行する
- LLM 機能（`LLMSuccessorFetcher` / `LLMSegmentConverter` / `LLMMisconversionChecker`）は `FoundationModels` フレームワーク（Apple Intelligence）を使用。macOS 26 で Apple Intelligence が有効なデバイスでないと `SystemLanguageModel.default.availability` が `.unavailable` を返しスキップされる（IME 基本動作は継続）

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

詳細は [`docs/domain/architecture.md`](docs/domain/architecture.md) を参照。

| コンポーネント | 役割 |
|--------------|------|
| `InputController` | IMK ブリッジ。NSEvent → InputHandler 委譲、LLM 系（`LLMSuccessorFetcher` / `LLMSegmentConverter` / `LLMMisconversionChecker`）管理 |
| `InputHandler` | 入力ロジック本体（テスト可能、Swift 6）。extension 分割: NormalInput / Candidates / DateTime / Numbers / SegmentMode / SuccessorMode |
| `TextInputClient` | `insertText` / `setMarkedText` の DI プロトコル。テスト時は `MockTextClient` |
| `CompositionState` | 未確定文字列（composedHiragana + pendingRomaji）。`SegmentState` を内包 |
| `RomajiConverter` | ローマ字→ひらがな変換ルール |
| `AzooKeyConverter` | ひらがな→漢字変換エンジンラッパー（Zenzai 有効フラグ・LRU キャッシュ） |
| `DatabaseManager` | 変換履歴・N-gram・ユーザー辞書・境界学習の SQLite 管理（6テーブル）。extension 分割: History / Ngram / Boundary / UserDict |
| `SettingsWindowController` 他 | 設定画面（5タブ: Bi-gram / Tri-gram / ユーザー辞書 / 変換履歴 / Zenzai）。`CleanserSheetViewController` はシートとして統合 |
| `ZenzaiSettings` / `ZenzaiViewController` | Zenzai 有効フラグ・プロフィール・推論トークン上限（UserDefaults） |
| `CandidateAction` / `CandidateContext` | InputHandler が返す候補ウィンドウ操作指示と状態スナップショット（`historyEnd` / `fixedEnd` が重要） |
| `AppDelegate` | IMKServer 起動 + Edit メニュー登録 |
| `SurroundingIMKContext` | カーソル前後テキスト取得ユーティリティ（LLM 系が使用） |
| `DebugSocketServer` | Unix ドメインソケット経由のデバッグサーバー（`#if DEBUG`）。`/keynaco-ime-sandbox` スキルが使用 |
| `EventViewerWindow` / `IMESandboxWindow` | デバッグ用 GUI ツール（`keynaco/Debug/`） |
| `KanaUtils` | ひらがな↔カタカナ変換（`hiraganaToKatakana` / `hiraganaToHankakuKatakana` / `toZenkakuAscii`） |
| `NotificationNames` | KeynacoCore 公開の通知名（successorPending / misconversionFound / misconversionCleared） |

## テスト方針

### Core モジュール（KeynacoCore）への型追加

`Core/` は独立 SPM ライブラリ。App（`keynaco/`）から参照する型・イニシャライザ・メソッド・プロパティはすべて `public`（必要なら `open`）が必須。`@testable import KeynacoCore` でテストからは `internal` でもアクセスできるが App からは見えないため注意。

### XCUITest / CGEvent による E2E テストは採用しない

IME はバックグラウンドエージェントとして動作するため、`XCUIElement.typeText()` はカスタム IME をバイパスする。`CGEvent` を用いた物理的なキー送信は Accessibility 権限に依存し CI で不安定になる。

### InputHandler + TextInputClient モック（採用）

`InputController` のロジックを `InputHandler`（純粋 Swift struct）に抽出し、テキスト操作の出力先を `TextInputClient` プロトコルで抽象化する。テストでは `MockTextClient` を渡して `insertText` / `setMarkedText` の呼び出しを検証する。

## キー入力の挙動（特殊ケース）

- **Shift+英字（日本語モード、組成前）**: 英字単語モードを開始。以降の小文字も `composedHiragana` に直接蓄積（ローマ字変換しない）。AzooKey は呼ばず、履歴検索キーは小文字正規化。`GitHub` 等の混在ケース入力に対応。
- **英数キー（keyCode 102）**: 組成中なら確定してASCIIモードへ。`ignoreNextModeSwitch` フラグで macOS の二重送信を防ぐ
- **かなキー（keyCode 104）**: 日本語モードに戻る
- **`baseCharacters` vs `characters`**: Shift押下時、`characters`はシフト文字（`>`）、`baseCharacters`は素文字（`.`）。`punctuationMap`は`baseCharacters`で照合するため Shift+`,`/`.` が `<`/`>` になる
- **Shift+ASCII 文字（日本語モード中）**: 組成バッファに英字として蓄積される（`pendingRomaji` 経由ではなく直接 `composedHiragana` に追加）。Enter で確定。
- **Shift+句読点**: `,` → `<`、`.` → `>`（`punctuationMap` は Shift なし時のみ `、` / `。` に変換）。
- **Shift+Delete（候補選択中）**: 選択中の候補を変換履歴 DB から削除。
- **Shift+Tab / Shift+矢印（セグメントモード中）**: セグメント境界を1文字単位で調整。
- **F6–F10（組成中のみ）**: F6=ひらがな、F7=全角カタカナ、F8=半角カタカナ、F9=全角ASCII、F10=半角ASCII で即時確定。`handleFunctionKey()` 参照。
- **z シーケンス（組成中・組成前どちらでも）**: `z` + 記号/矢印キーで特殊文字を即時挿入。`z-` → `〜`、`z/` → `・`、`z.` → `…`、`z,` → `、`、`z→` → `→`、`z←` → `←`（`zCharMap` / `zArrowMap`）。

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
