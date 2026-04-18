# ykey

macOS 向け IME（Input Method Editor）。InputMethodKit + SQLite。

## ディレクトリ構成

| パス | 内容 |
|------|------|
| `Sources/` | アプリ本体（Swift ソース + Info.plist + entitlements） |
| `Tests/` | ユニットテスト（XCTest） |
| `Packages/AzooKeyKanaKanjiConverter` | ローカル Swift Package（変換エンジン） |
| `plans/` | 設計・調査メモ（`PLAN<YYMMDD>.md` 形式） |
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
- `/deploy` スキル（Claude Code 内）: ビルドからインストールまでを一括実行する

## テスト実行

```bash
xcodegen generate  # .xcodeproj がない場合のみ
xcodebuild test -scheme ykey -destination "platform=macOS"
```

## コンポーネント構成

- `InputController` = IMK ブリッジ（NSEvent 展開 → InputHandler 委譲）。`CandidateWindow` もここで管理
- `InputHandler` = 入力ロジック本体（テスト可能）、Swift 6 strict concurrency。`isAsciiMode` は `static` — 全インスタンス共有でアプリ切替後もモードを維持。テストの `setUp` でリセット必須
- `TextInputClient` = `insertText` / `setMarkedText` を抽象化するプロトコル（テストでは `MockTextClient`、本番では IMK クライアントをラップ）
- `CompositionState` = 未確定文字列の状態（composedHiragana + pendingRomaji）、ローマ字→ひらがな変換を内包
  - `SegmentState`（`segmentState`）を持ち `isSegmentMode` が true の間はセグメント調整モード。Space 押下時に AzooKey の変換結果をセグメント分割して遷移
- `RomajiConverter` = ローマ字→ひらがな変換ルールの実装
- `AzooKeyConverter` = ひらがな→漢字変換エンジン（`KanaKanjiConverterModuleWithDefaultDictionary` のラッパー、学習データを `~/Library/Application Support/ykey/` に保存）
- `DatabaseManager` = 変換履歴の記録・参照・削除（SKK辞書検索ではない）。`InputHandler` のイニシャライザで DI（テストは `inMemory: true`）
- `CandidateAction` / `CandidateContext` = `InputHandler` が返す候補ウィンドウ操作指示と状態スナップショット。`isExplicitlySelected`（↑↓で動かしたか）と `historyEnd`（履歴セクションの末尾インデックス）が重要

変換エンジンは `AzooKeyKanaKanjiConverter`（ローカルパッケージ）の組み込み辞書を使用。SQLite は変換履歴のみ管理する。
カタカナ候補は `hiraganaToKatakana` で自動生成し、変換候補の先頭（履歴より後）に差し込む。

## テスト方針

### XCUITest / CGEvent による E2E テストは採用しない

IME はバックグラウンドエージェントとして動作するため、`XCUIElement.typeText()` はカスタム IME をバイパスする。`CGEvent` を用いた物理的なキー送信は Accessibility 権限に依存し CI で不安定になる。

### InputHandler + TextInputClient モック（採用）

`InputController` のロジックを `InputHandler`（純粋 Swift struct）に抽出し、テキスト操作の出力先を `TextInputClient` プロトコルで抽象化する。テストでは `MockTextClient` を渡して `insertText` / `setMarkedText` の呼び出しを検証する。

### Shift キー入力の挙動

- **英数キー（keyCode 102）**: 組成中なら確定してASCIIモードへ。`ignoreNextModeSwitch` フラグで macOS の二重送信を防ぐ
- **かなキー（keyCode 104）**: 日本語モードに戻る
- **`baseCharacters` vs `characters`**: Shift押下時、`characters`はシフト文字（`>`）、`baseCharacters`は素文字（`.`）。`punctuationMap`は`baseCharacters`で照合するため Shift+`,`/`.` が `<`/`>` になる
- **Shift+ASCII 文字（日本語モード中）**: 組成バッファに英字として蓄積される（`pendingRomaji` 経由ではなく直接 `composedHiragana` に追加）。Enter で確定。
- **Shift+句読点**: `,` → `<`、`.` → `>`（`punctuationMap` は Shift なし時のみ `、` / `。` に変換）。
- **Shift+Delete（候補選択中）**: 選択中の候補を変換履歴 DB から削除。
- **Shift+Tab / Shift+矢印（セグメントモード中）**: セグメント境界を1文字単位で調整。

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

### flagsChanged で Caps Lock を検知する

Caps Lock トグルは未実装。実装時は `handle(event:client:)` で `.flagsChanged` イベントを受け取り、`NSEvent.ModifierFlags.capsLock` で ON/OFF を判定する。`inputText` では flagsChanged を受け取れない。

## 不採用の機能

### 数字キー（1–9）による候補直接確定

候補ウィンドウ表示中に 1–9 を押すと対応する候補を確定するアイデアは採用しない。

理由: 候補ウィンドウが履歴ヒットで自動表示される仕様のため、数字の連続入力（"123" など）で 3 文字目が候補選択として誤作動する。ASCII 組成中は無効にする回避策も試みたが、体験が悪いと判断して廃止。
