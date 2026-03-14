# ykey

macOS 向け IME（Input Method Editor）。InputMethodKit + SQLite。

## ビルド・インストール

```bash
xcodegen generate
xcodebuild archive -scheme ykey -archivePath /tmp/ykey.xcarchive -configuration Release CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=R2ZZ3ALJ36
sudo rm -rf "/Library/Input Methods/ykey.app"
sudo cp -R /tmp/ykey.xcarchive/Products/Applications/ykey.app "/Library/Input Methods/"
sudo /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Library/Input Methods/ykey.app"
```

- `xcodebuild archive`（`build` ではない）で Release ビルドする
- インストール先は `/Library/Input Methods/`（sudo 必要）。`~/Library/` ではない
- インストール後、ログアウト→ログインで反映。System Settings → キーボード → 入力ソース → 英語 で追加

## macOS 26 IME の罠

### Bundle ID に "inputmethod" が必須

macOS 26 では TIS がサードパーティ IME を認識するために Bundle ID に `inputmethod` の文字列が必要。これがないと `TISRegisterInputSource` は成功を返すが `TISCreateInputSourceList` に現れない。サイレントに失敗するため原因特定が極めて困難。

### Info.plist は xcodegen に上書きさせない

`project.yml` に `info:` セクションを入れると xcodegen が Info.plist を上書きする。`INFOPLIST_FILE` 設定のみで参照すること。

### inputText の modifiers は Int 型

`IMKInputController.inputText(_:key:modifiers:client:)` の `modifiers` は `NSEvent.ModifierFlags` ではなく `Int`。間違えるとオーバーライドが認識されない。

### Development 署名で spctl -a は "rejected" になる

正常動作する。Gatekeeper の仕様であり問題ない。
