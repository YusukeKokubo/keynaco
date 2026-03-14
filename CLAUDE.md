# ykey

macOS 向け IME（Input Method Editor）。InputMethodKit + SQLite。

## プロジェクト構成

- `Sources/` - メインアプリのソース
  - `main.swift` - エントリポイント（`NSApplicationMain`）
  - `NSManualApplication.swift` - NSApplication サブクラス（NSPrincipalClass）
  - `AppDelegate.swift` - IMKServer 起動
  - `InputController.swift` - IMKInputController サブクラス（入力処理・候補表示）
  - `DatabaseManager.swift` - SQLite3 ラッパー（履歴の保存・検索）
  - `Info.plist` - IME 登録情報（手動管理、xcodegen で上書きしない）
  - `ykey.entitlements` - App Sandbox + Mach サービス登録
- `project.yml` - xcodegen 設定

## ビルド・インストール

```bash
xcodegen generate
xcodebuild archive -scheme ykey -archivePath /tmp/ykey.xcarchive -configuration Release CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=R2ZZ3ALJ36
sudo rm -rf "/Library/Input Methods/ykey.app"
sudo cp -R /tmp/ykey.xcarchive/Products/Applications/ykey.app "/Library/Input Methods/"
sudo /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Library/Input Methods/ykey.app"
```

インストール後、ログアウト→ログインで反映。System Settings → キーボード → 入力ソース → 英語 で追加。

## macOS 26 IME の重要な制約

### Bundle ID に "inputmethod" が必須

macOS 26 では、TIS（Text Input Source）がサードパーティ IME を認識するために Bundle ID に `inputmethod` の文字列が必要。これがないと `TISRegisterInputSource` は成功を返すが、`TISCreateInputSourceList` に表示されない。

- 現在: `com.yusuke.inputmethod.ykey`
- azooKey: `dev.ensan.inputmethod.azooKeyMac`

### InputMethodConnectionName に `_Connection` サフィックス

`$(PRODUCT_BUNDLE_IDENTIFIER)_Connection` 形式が必要。

### App Sandbox + Mach サービス登録

`ykey.entitlements` で以下を設定：
- `com.apple.security.app-sandbox: true`
- `com.apple.security.temporary-exception.mach-register.global-name: $(PRODUCT_BUNDLE_IDENTIFIER)_Connection`

### NSManualApplication パターン

azooKey に倣い、`NSManualApplication`（NSApplication サブクラス）を `NSPrincipalClass` として使用。`main.swift` は `NSApplicationMain` を呼ぶだけ。

### ComponentInputModeDict の新形式

古い `tsInputMethodCharacterSubsets` ではなく `tsInputModeListKey` ディクショナリ形式を使用。入力モードのキーは `com.apple.inputmethod.Roman` 等の標準識別子を使う。

### インストール先

`/Library/Input Methods/`（sudo 必要）。`~/Library/Input Methods/` ではない。

### コード署名

`CODE_SIGN_STYLE: Automatic` + `DEVELOPMENT_TEAM: R2ZZ3ALJ36`。`xcodebuild archive`（Release）でビルド。Development 署名の場合 `spctl -a` は "rejected" になるが正常動作する。

### Info.plist は手動管理

`project.yml` に `info:` セクションを入れると xcodegen が Info.plist を上書きするため、`INFOPLIST_FILE` 設定のみで参照する。

## InputController の注意点

- `inputText` のシグネチャ: `modifiers` パラメータは `Int` 型（`NSEvent.ModifierFlags` ではない）
- 候補ウィンドウ: `IMKCandidates(server:panelType:)` で `kIMKSingleColumnScrollingCandidatePanel`
