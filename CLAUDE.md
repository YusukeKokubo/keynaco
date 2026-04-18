# ykey

macOS 向け IME（Input Method Editor）。InputMethodKit + SQLite。

## ディレクトリ構成

| パス | 内容 |
|------|------|
| `Sources/` | アプリ本体（Swift ソース + Info.plist + entitlements） |
| `Tests/` | ユニットテスト（XCTest） |
| `Resources/` | SKK-JISYO-L.utf8 等（辞書ファイル） |
| `Packages/AzooKeyKanaKanjiConverter` | ローカル Swift Package（変換エンジン） |
| `plans/` | 設計・調査メモ |
| `project.yml` | XcodeGen 設定 |

### 起動チェーン（IMK ブートストラップ）

`main.swift` → `NSManualApplication`（`NSApplication` サブクラス）→ `AppDelegate` →
`IMKServer` を生成し `InputController`（`IMKInputController` サブクラス）を登録。
`@objc(ClassName)` アノテーションが必須（後述）。

## ビルド・インストール

```bash
xcodegen generate
xcodebuild build -scheme ykey -configuration Debug
```

- Build Post-action（`project.yml` の `schemes`）により `/Library/Input Methods/` への自動コピーとプロセス再起動が行われる
- 初回セットアップ: `sudo chmod -R +a "$(whoami) allow list,add_file,search,add_subdirectory,delete_child,delete,read,write,execute" "/Library/Input Methods"` が必要（所有者を root のまま ACL で自分にだけ権限を付与）
- `~/Library/Input Methods/` は使わない（入力ソースが重複登録される）
- 初回インストール後、ログアウト→ログインで反映。System Settings → キーボード → 入力ソース → 英語 で追加
- `install.sh` は古いスクリプト（`~/Library/` を使っており非推奨）。Build Post-action が自動でインストールするため不要
- `/deploy` スキル（Claude Code 内）: ビルドからインストールまでを一括実行する

## テスト実行

```bash
xcodebuild test -scheme ykey -destination "platform=macOS"
```

## テスト方針

### XCUITest / CGEvent による E2E テストは採用しない

IME はバックグラウンドエージェントとして動作するため、`XCUIElement.typeText()` はカスタム IME をバイパスする。`CGEvent` を用いた物理的なキー送信は Accessibility 権限に依存し CI で不安定になる。

### InputHandler + TextInputClient モック（採用）

`InputController` のロジックを `InputHandler`（純粋 Swift struct）に抽出し、テキスト操作の出力先を `TextInputClient` プロトコルで抽象化する。テストでは `MockTextClient` を渡して `insertText` / `setMarkedText` の呼び出しを検証する。

- `InputController` = IMK ブリッジ（NSEvent 展開 → InputHandler 委譲）
- `InputHandler` = 入力ロジック本体（テスト可能）、Swift 6 strict concurrency
- `TextInputClient` = `insertText` / `setMarkedText` を抽象化するプロトコル（テストでは `MockTextClient`、本番では IMK クライアントをラップ）
- `CompositionState` = 未確定文字列の状態（composedHiragana + pendingRomaji）、ローマ字→ひらがな変換を内包
- `RomajiConverter` = ローマ字→ひらがな変換ルールの実装
- `AzooKeyConverter` = ひらがな→漢字変換エンジン（`KanaKanjiConverterModuleWithDefaultDictionary` のラッパー、学習データを `~/Library/Application Support/ykey/` に保存）
- `DatabaseManager` = 変換履歴の記録・参照・削除（SKK辞書検索ではない）。`InputHandler` のイニシャライザで DI（テストは `inMemory: true`）
- `CandidateWindow` は `InputController` 側で管理し `InputHandler` には渡さない
- `CandidateAction` / `CandidateContext` = `InputHandler` が返す候補ウィンドウ操作指示と状態スナップショット

変換エンジンは `AzooKeyKanaKanjiConverter`（ローカルパッケージ）の組み込み辞書を使用。SQLite は変換履歴のみ管理する。

## macOS 26 IME の罠

### Bundle ID に "inputmethod" が必須

macOS 26 では TIS がサードパーティ IME を認識するために Bundle ID に `inputmethod` の文字列が必要。これがないと `TISRegisterInputSource` は成功を返すが `TISCreateInputSourceList` に現れない。サイレントに失敗するため原因特定が極めて困難。

### Info.plist は xcodegen に上書きさせない

`project.yml` に `info:` セクションを入れると xcodegen が Info.plist を上書きする。`INFOPLIST_FILE` 設定のみで参照すること。

### inputText より handle(event:client:) を使う

`inputText(_:key:modifiers:client:)` は矢印キー等の特殊キーを受け取れない。`handle(_ event: NSEvent!, client sender: Any!) -> Bool` をオーバーライドすること。

### Swift クラスに @objc が必須

InputMethodKit は ObjC ランタイムでクラスを探す。Swift の `IMKInputController` サブクラスや `NSApplication` サブクラスには `@objc(ClassName)` を付けないと実行時に見つからない。Info.plist のクラス名もモジュールプレフィックスなしにする（`ykey.InputController` ではなく `InputController`）。

### IMKCandidates は macOS 26 で使えない

`IMKCandidates` の `selectCandidate(withIdentifier:)` が動作しない。候補ウィンドウは `NSWindow(.borderless, level: .popUpMenu)` + `NSTableView` で自作する。

### Development 署名で spctl -a は "rejected" になる

正常動作する。Gatekeeper の仕様であり問題ない。
