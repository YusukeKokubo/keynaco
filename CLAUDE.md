# keynaco

macOS 向け IME（Input Method Editor）。InputMethodKit + SQLite。

## ドメイン知識

| ドキュメント | 内容 |
|-------------|------|
| [`docs/domain/glossary.md`](docs/domain/glossary.md) | 用語定義・不変条件 |
| [`docs/domain/states.md`](docs/domain/states.md) | 状態遷移図・状態別キー動作 |
| [`docs/domain/scenarios.md`](docs/domain/scenarios.md) | 具体的な入力トレース例 |

**更新ルール**: キー入力の挙動・状態遷移・候補表示ロジックに影響する変更を加えたとき、コードと同じコミットで該当箇所を更新する。
- 用語の定義・不変条件が変わった → `glossary.md`
- 状態遷移・キー動作が変わった → `states.md`
- 入力トレースの具体例が変わった → `scenarios.md`

## ディレクトリ構成

| パス | 内容 |
|------|------|
| `Sources/` | アプリ本体（Swift ソース + Info.plist + entitlements） |
| `Sources/Debug/` | デバッグ用ツール（`EventViewerWindow` 等、本番動作には影響しない） |
| `Tests/` | ユニットテスト（XCTest） |
| `docs/domain/` | ドメイン知識ドキュメント（用語・状態遷移・シナリオ） |
| `plans/` | 設計・調査メモ（`PLAN<YYMMDD>.md` 形式） |
| `project.yml` | XcodeGen 設定 |
| `make_icons.swift` | アイコン素材を各サイズに切り出すスクリプト |

### 起動チェーン（IMK ブートストラップ）

`main.swift` → `NSManualApplication`（`NSApplication` サブクラス）→ `AppDelegate` →
`IMKServer` を生成し `InputController`（`IMKInputController` サブクラス）を登録。
`@objc(ClassName)` アノテーションが必須（後述）。

## ビルド・インストール

```bash
xcodegen generate
xcodebuild build -scheme keynaco -configuration Debug
```

- Build Post-action（`project.yml` の `schemes`）により `/Library/Input Methods/` への自動コピーとプロセス再起動が行われる
- `SWIFT_VERSION: "6.0"`（strict concurrency モード）。新しいクラス・struct を追加する際は `@MainActor`、`Sendable`、または `@unchecked Sendable` のいずれかが必要
- バージョン番号は git tag で管理。`git tag v0.1.0` → ビルド時に `CFBundleShortVersionString` / `CFBundleVersion` に自動注入（post-action が `PlistBuddy` で書き換え）。`PlistBuddy` 後は署名が無効化されるため、post-action の最後で `codesign --force --deep --sign` による再署名が必須（無いと macOS 26 が SIGKILL でプロセスを落とす）
- 初回セットアップ: `sudo chmod -R +a "$(whoami) allow list,add_file,search,add_subdirectory,delete_child,delete,read,write,execute" "/Library/Input Methods"` が必要（所有者を root のまま ACL で自分にだけ権限を付与）
- `~/Library/Input Methods/` は使わない（入力ソースが重複登録される）
- 初回インストール後、ログアウト→ログインで反映。System Settings → キーボード → 入力ソース → 英語 で追加
- 起動のたびに `TISRegisterInputSource` を呼んで入力ソースを自動登録する。初回のみログアウト→ログインが必要（TIS がキャッシュを更新するため）
- `/deploy` スキル（Claude Code 内）: ビルドからインストールまでを一括実行する

## テスト実行

```bash
xcodegen generate  # .xcodeproj がない場合のみ
xcodebuild test -scheme keynaco -destination "platform=macOS"
```

## コンポーネント構成

- `InputController` = IMK ブリッジ（NSEvent 展開 → InputHandler 委譲）。`CandidateWindow` もここで管理
- `InputHandler` = 入力ロジック本体（テスト可能）、Swift 6 strict concurrency。実装は機能ごとに extension 分割: `InputHandler+Candidates.swift`（候補リスト・通常入力）、`InputHandler+SegmentMode.swift`（文節調整）、`InputHandler+SuccessorMode.swift`（後続語予測）。`isAsciiMode` は `static` — 全インスタンス共有でアプリ切替後もモードを維持。テストの `setUp` でリセット必須。`isBracketMode`（`bracketCandidates != nil`）: `[`/`(`等の括弧キー入力時に対応する全角括弧の候補ウィンドウを表示するモード（`bracketOptions` マップで ASCII → 全角候補列に変換）。`sentenceTerminators`（`。！？\n`）確定時に `committedHistory.removeAll()` を呼び、文をまたいだ n-gram 学習を防止する
- `TextInputClient` = `insertText` / `setMarkedText` を抽象化するプロトコル（テストでは `MockTextClient`、本番では IMK クライアントをラップ）
- `CompositionState` = 未確定文字列の状態（composedHiragana + pendingRomaji）、ローマ字→ひらがな変換を内包。`hiddenPendingN` フラグで "nn" → "ん" 後の pending "n" を不可視化（標準 IME 準拠）。Backspace 時は "ん" + hidden n をまとめて1操作で削除する
  - `SegmentState`（`segmentState`）を持ち `isSegmentMode` が true の間はセグメント調整モード。Space 押下時に AzooKey の変換結果をセグメント分割して遷移
- `RomajiConverter` = ローマ字→ひらがな変換ルールの実装
- `AzooKeyConverter` = ひらがな→漢字変換エンジン（`KanaKanjiConverterModuleWithDefaultDictionary` のラッパー、学習データを `~/Library/Application Support/keynaco/` に保存）
- `DatabaseManager` = 変換履歴の記録・参照・削除（SKK辞書検索ではない）。`InputHandler` のイニシャライザで DI（テストは `inMemory: true`）。`history` / `bigram` / `trigram` / `skip_bigram` / `user_dict` の **5 テーブル**を持つ。実 DB は `~/Library/Application Support/keynaco/history.db`。SQLite 定型句は private ヘルパー `queryStrings` / `execute`（クロージャ方式）に集約。全 fetch/record で `nowEpoch()`（`clock` var 経由）を使い時間減衰スコア `count / (1 + age_days / τ)` でソート（τ=30日）。`user_dict` のみ time-decay なし（永続登録）
- `SettingsWindowController` / `BigramViewController` / `HistoryViewController` / `UserDictViewController` = `Sources/Settings/` 配下の設定画面。`NSTabViewController` で「Bi-gram」「ユーザー辞書」「変換履歴」タブを提供。Bi-gram は JSON エクスポート/インポート対応。ユーザー辞書は読み（ひらがな）→登録テキストの CRUD
- `CandidateAction` / `CandidateContext` = `InputHandler` が返す候補ウィンドウ操作指示と状態スナップショット。`isExplicitlySelected`（↑↓で動かしたか）と `historyEnd`（固定+ユーザー辞書+予測+履歴セクションの末尾インデックス）と `fixedEnd`（カナ固定+ユーザー辞書の末尾インデックス。`fixedEnd <= row < historyEnd` の行が Shift+Delete 可能）が重要
- `AppDelegate` = `IMKServer` 起動 + `setupMainMenu()`（Edit メニュー登録。アクセサリアプリは既定でメインメニューを持たず Cmd+V/A/Z が届かないため）
- `EventViewerWindow` = `Sources/Debug/EventViewerWindow.swift`。`AppDelegate` が NSStatusItem（⌨アイコン）として常駐し、メニューから起動。keyCode・chars・mods・consumed・action・app をリアルタイム表示。確定テキストと候補リストをキャプチャしてクリップボードにコピー可能。JSONL エクスポートで `~/Library/Application Support/keynaco/sessions/` に保存。デバッグ用途

変換エンジンは `AzooKeyKanaKanjiConverter`（ローカルパッケージ）の組み込み辞書を使用。SQLite は変換履歴のみ管理する。
カタカナ候補は `hiraganaToKatakana` で自動生成し、変換候補の先頭（履歴より後）に差し込む。
`KanaUtils` = ひらがな↔カタカナ変換ユーティリティ（`hiraganaToKatakana` / `hiraganaToHankakuKatakana` / `toZenkakuAscii`）。F7–F9 変換確定とカタカナ候補生成で使用。

### Successor モード（isSuccessorMode / successorFirstChar / pendingSuccessorCandidates）

確定直後に `suggestSuccessors()` が後続語候補を準備する。候補は以下の順：

1. `db.fetchTrigramTop(prev2:prev1:)` の上位（2語前コンテキスト優先）
2. `db.fetchBigramTop(prev:)` の上位（tri-gram に含まれないもの）
3. `db.fetchSkipBigramTop(prev:)` の上位（`mostRecentContentWord` を prev として、tri-gram・bi-gram にない候補を追加）
4. `isNounLike(last)` が真のときのみ、格助詞固定リスト（`InputHandler.particles`）を tail に fallback として並べる

bi-gram が空かつ格助詞 fallback も出ないケース（ひらがな末尾 + 学習ゼロ等）では `.dismiss` を返しモードには入らない。

**N-gram 候補の遅延表示と読みフィルタ**: N-gram 由来の候補がある場合、`suggestSuccessors()` は まず `fetchBigramTopCount(prev: last)` で前語に対する bi-gram 上位使用回数を取得する。`successorImmediateThreshold`（デフォルト 5）以上なら「高信頼ペア」とみなして即時表示（`.show`）。閾値未満なら候補を `pendingSuccessorCandidates` に保存して `.dismiss` を返す（1打目待ち）。1打目が入力されたとき、`romajiToInitialKana` でそのキーの読み先頭候補かなを取得し、DB を再クエリして一致する候補のみ `.show` する（読みが一致しなければモード解除）。格助詞 fallback のみ（N-gram なし、名詞末尾の場合）は従来通り即時表示する。

- `successorFirstChar`: 頭文字 1 打目のバッファリング。`particleRomajiMap` による格助詞 fast-path が効くのは `isNounLike` のときのみ。N-gram 保留表示後の 2 打目でモード解除する際にも使用する。
- Successor モード中は `setMarkedText` に実テキストを渡す。空文字だと Electron 系アプリが Enter を IME に転送せずアプリ側で処理してしまうため。
- 候補確定後は `suggestSuccessors()` を再呼び出しし、次の bi-gram / tri-gram 候補があれば連鎖表示を継続する。候補が空なら自然に `.dismiss`（格助詞チェックは廃止）。
- Successor モード中に右矢印（→）を押すとモードをキャンセルし、通常の組成に戻る。
- **pendingRomaji 先読み予測**: Successor モード外で `composedHiragana` が空かつ `pendingRomaji` が1文字（`n` を除く）のとき `buildPendingCandidateList` が bi-gram/trigram/skip-bigram を先読みし、候補があれば `isSuccessorMode = true` へ移行。`n` は `ん` との曖昧さがあるため除外。候補ゼロなら `pendingRomaji` はそのまま通常組成を続ける。確定時（Space/Enter）に `confirmSuccessor()` が `pendingRomaji` をクリアする（`buildPendingCandidateList` 内ではクリアしない。Escape 後に続きのローマ字を入力できるようにするため）。

### 候補表示の優先順位

`buildCandidateList()` が組み立てる候補リスト（上が高優先）:

1. ひらがな / カタカナ固定候補（`fixedCount` 件、スクロール外の先頭に挿入）
2. **ユーザー辞書**候補（完全一致のみ、`fixedCount` の直後に挿入。`fixedEnd = fixedCount + userDictCount`）
3. tri-gram → bi-gram 候補（`prev2Output` × `lastCommittedOutput` × 読みで tri-gram を優先、重複除去後にユーザー辞書の直後に挿入）
4. 履歴 exact（入力に完全一致）+ prefix（前方一致、完全一致を除外）
5. AzooKey 辞書候補

`autoShow=true`（文字入力中の自動表示）のとき、履歴・辞書・bi-gram・ユーザー辞書が0件なら表示しない。

Shift+Delete 可能な範囲: `fixedEnd <= row < historyEnd`（ユーザー辞書行 `fixedCount <= row < fixedEnd` は削除不可）。

## テスト方針

### XCUITest / CGEvent による E2E テストは採用しない

IME はバックグラウンドエージェントとして動作するため、`XCUIElement.typeText()` はカスタム IME をバイパスする。`CGEvent` を用いた物理的なキー送信は Accessibility 権限に依存し CI で不安定になる。

### InputHandler + TextInputClient モック（採用）

`InputController` のロジックを `InputHandler`（純粋 Swift struct）に抽出し、テキスト操作の出力先を `TextInputClient` プロトコルで抽象化する。テストでは `MockTextClient` を渡して `insertText` / `setMarkedText` の呼び出しを検証する。

### Shift キー入力の挙動

- **Shift+英字（日本語モード、組成前）**: 英字単語モードを開始。以降の小文字も `composedHiragana` に直接蓄積（ローマ字変換しない）。AzooKey は呼ばず、履歴検索キーは小文字正規化。`GitHub` 等の混在ケース入力に対応。
- **英数キー（keyCode 102）**: 組成中なら確定してASCIIモードへ。`ignoreNextModeSwitch` フラグで macOS の二重送信を防ぐ
- **かなキー（keyCode 104）**: 日本語モードに戻る
- **`baseCharacters` vs `characters`**: Shift押下時、`characters`はシフト文字（`>`）、`baseCharacters`は素文字（`.`）。`punctuationMap`は`baseCharacters`で照合するため Shift+`,`/`.` が `<`/`>` になる
- **Shift+ASCII 文字（日本語モード中）**: 組成バッファに英字として蓄積される（`pendingRomaji` 経由ではなく直接 `composedHiragana` に追加）。Enter で確定。
- **Shift+句読点**: `,` → `<`、`.` → `>`（`punctuationMap` は Shift なし時のみ `、` / `。` に変換）。
- **Shift+Delete（候補選択中）**: 選択中の候補を変換履歴 DB から削除。
- **Shift+Tab / Shift+矢印（セグメントモード中）**: セグメント境界を1文字単位で調整。
- **F6–F10（組成中のみ）**: F6=ひらがな、F7=全角カタカナ、F8=半角カタカナ、F9=全角ASCII、F10=半角ASCII で即時確定。`handleFunctionKey()` 参照。

## macOS 26 IME の罠

### Bundle ID に "inputmethod" が必須（InputMethodKit 全般の仕様）

TIS がサードパーティ IME を認識するために Bundle ID に `inputmethod` の文字列が必要（macOS 26 固有ではなく InputMethodKit 長年の仕様）。これがないと `TISRegisterInputSource` は成功を返すが `TISCreateInputSourceList` に現れない。サイレントに失敗するため原因特定が極めて困難。

### Info.plist は xcodegen に上書きさせない

`project.yml` に `info:` セクションを入れると xcodegen が Info.plist を上書きする。`INFOPLIST_FILE` 設定のみで参照すること。

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
